#!/usr/bin/env bats
# Unit tests for the two construct-validity checks' suite-level controls: run-openloop.sh
# starts on the suite run's recorded settings, prepares every rep like a scan rep (restart,
# guards, gated warm-up) and logs its aborts apart from the suite's failures log;
# run-predict-composition.sh refuses a running stack, runs each rep in a fresh container
# with a shuffled tier order and its recorded CPU quota, and merges the reps into a schema-2
# file. The open-loop functions are extracted from the live script text with docker and
# the guards stubbed; the composition script runs whole against a stubbed docker, which
# needs a host in a measurement power state (skipped otherwise).

setup_file() {
  export LT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export OPENLOOP_SH="${LT_DIR}/run-openloop.sh"
  export COMPOSITION_SH="${LT_DIR}/run-predict-composition.sh"

  extract_fn() {
    awk -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { f = 1 } f { print } f && /^}/ { exit }' "$1"
  }
  export -f extract_fn
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  RUN_DIR="${WORKDIR}/suite_host_20260101T000000Z"
  mkdir -p "$RUN_DIR" "${WORKDIR}/bin"
  DOCKER_LOG="${WORKDIR}/docker.log"
  : > "$DOCKER_LOG"
  export RUN_DIR DOCKER_LOG
  JVM_OPTS="-Xms1536m -Xmx1536m -XX:+UseG1GC -XX:ParallelGCThreads=4 -XX:ConcGCThreads=1 -Dreactor.netty.ioWorkerCount=4"
  export JVM_OPTS

  # Recorded values that differ from docker-compose.yml's defaults, so a test can tell which
  # source the stack was started from.
  python3 - "$RUN_DIR/run_metadata.json" <<'EOF'
import json, os, subprocess, sys
lt = os.environ["LT_DIR"]
snapshot = subprocess.run(["bash", "-c", f". {lt}/lib/host-provenance.sh; . {lt}/lib/power-state.sh; power_state_snapshot"],
                          capture_output=True, text=True).stdout.strip()
json.dump({
    "power_state": {"turbo_required": "off", "snapshot": snapshot},
    "jvm_pinned_options": os.environ["JVM_OPTS"],
    "cores_used_by_suite": {"python_service_cpuset": "0-3", "transaction_service_cpuset": "4-5",
                            "k6_cpuset": "6-7", "python_service_cpus_quota": "4.0",
                            "transaction_service_cpus_quota": "2.0", "k6_cpus_quota": "2.0"},
    "suite_config": {"uvicorn_workers": "2", "thread_limiter_tokens": 32, "max_vus": 48, "cooldown_s": 10},
}, open(sys.argv[1], "w"))
EOF

  # docker stub: `compose config` renders the services from the exported settings (or a
  # *_RESOLVED override, to simulate drift), and every call is logged with those settings.
  cat > "${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $* | PYTHON_CPUSET=${PYTHON_CPUSET:-} PYTHON_CPUS=${PYTHON_CPUS:-} JAVA_CPUSET=${JAVA_CPUSET:-} K6_CPUSET=${K6_CPUSET:-} UVICORN_WORKERS=${UVICORN_WORKERS:-} THREAD_LIMITER_TOKENS=${THREAD_LIMITER_TOKENS:-}" >> "$DOCKER_LOG"
case " $* " in
  *" config "*)
    cat <<CFG
services:
  k6:
    cpus: ${K6_CPUS:-4.0}
    cpuset: "${K6_CPUSET:-10-11,14-15}"
  python-service:
    cpus: ${PYTHON_CPUS_RESOLVED:-${PYTHON_CPUS:-6.0}}
    cpuset: "${PYTHON_CPUSET_RESOLVED:-${PYTHON_CPUSET:-0-1,4-5,8-9}}"
    environment:
      THREAD_LIMITER_TOKENS: "${THREAD_LIMITER_TOKENS:-40}"
      UVICORN_WORKERS: "${UVICORN_WORKERS:-3}"
  transaction-service:
    cpus: ${JAVA_CPUS:-4.0}
    cpuset: "${JAVA_CPUSET:-2-3,6-7}"
    environment:
      JAVA_TOOL_OPTIONS: ${JVM_OPTS_RESOLVED:-$JVM_OPTS}
CFG
    ;;
esac
exit 0
EOF
  chmod +x "${WORKDIR}/bin/docker"
  export PATH="${WORKDIR}/bin:${PATH}"
}

# A runnable harness around run-openloop.sh's functions, under its own `set -euo pipefail`,
# with lib/suite-stack.sh's real shuffled/restart_stack/compose_service_value and every guard
# that needs a live stack stubbed to a step line.
openloop_harness() {
  {
    echo 'set -euo pipefail'
    echo "LIB_DIR='${LT_DIR}/lib'; COMPOSE_FILE=fake-compose.yml; RUN_DIR='${RUN_DIR}'; RESULTS_DIR='${RUN_DIR}'"
    echo "OPENLOOP_LOG='${RUN_DIR}/openloop_log.txt'; CPU_PIN_LOG='${RUN_DIR}/openloop_cpu_pin_check_log.txt'"
    echo "FAILURES_LOG='${RUN_DIR}/openloop_failures_log.txt'; CURRENT_REP=none; OPENLOOP_TARGET=28"
    echo ". '${LT_DIR}/lib/run-layout.sh'; . '${LT_DIR}/lib/thermal.sh'; . '${LT_DIR}/lib/jvm-pins.sh'; . '${LT_DIR}/lib/suite-stack.sh'"
    for fn in suite_metadata load_recorded_settings verify_recorded_settings archive_previous_openloop \
              openloop_rep abort_suite _log_uncaught_exit; do
      extract_fn "$OPENLOOP_SH" "$fn"
    done
    for fn in record_env_sample check_power_state wait_for_ready verify_cpu_pinning verify_jvm_flag_pins \
              verify_tiers verify_tiers_runtime verify_jvm_thread_pins check_thermal_safety archive_gc_log \
              log_warmup_verdict; do
      echo "${fn}() { echo \"step ${fn} \$*\"; }"
    done
    echo 'converge_warmup() { echo "step converge_warmup $*"; }'
    echo 'run_cell() { echo "step run_cell $2"; }'
    echo 'finalize_result() { echo "step finalize_result $1"; }'
    echo 'sleep() { echo "step sleep $1"; }'
    cat
  } > "${WORKDIR}/harness.sh"
}

# --- run-openloop.sh: the recorded settings ---

@test "run-openloop.sh: the stack starts on the suite run's recorded settings, not compose's defaults" {
  openloop_harness <<'EOF'
load_recorded_settings
verify_recorded_settings
restart_stack
echo "service_cpusets=${SERVICE_CPUSETS} pinned=${PINNED_CPUS} tokens=${EXPECTED_THREAD_LIMITER_TOKENS}"
echo "maxvus=${SUITE_MAX_VUS} cooldown=${SUITE_COOLDOWN_S}"
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"service_cpusets=python=0-3 java=4-5 k6=6-7 pinned=0-3,4-5,6-7 tokens=32"* ]]
  [[ "$output" == *"maxvus=48 cooldown=10"* ]]
  grep -q '^docker compose -f fake-compose.yml up -d --wait | PYTHON_CPUSET=0-3 PYTHON_CPUS=4.0 JAVA_CPUSET=4-5 K6_CPUSET=6-7 UVICORN_WORKERS=2 THREAD_LIMITER_TOKENS=32$' "$DOCKER_LOG"
  [ "$(grep -c '^recorded_setting ' "${RUN_DIR}/openloop_cpu_pin_check_log.txt")" -eq 8 ]
  [ ! -e "${RUN_DIR}/openloop_failures_log.txt" ]
}

@test "run-openloop.sh: a setting the suite run did not record is refused" {
  python3 - "$RUN_DIR/run_metadata.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["suite_config"]["uvicorn_workers"] = "unknown"
json.dump(m, open(sys.argv[1], "w"))
EOF
  openloop_harness <<'EOF'
load_recorded_settings
echo "not reached"
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded no suite_config.uvicorn_workers"* ]]
  [[ "$output" != *"not reached"* ]]
}

@test "run-openloop.sh: a resolved setting or JVM options that differ from the record abort into its own log" {
  openloop_harness <<'EOF'
load_recorded_settings
verify_recorded_settings
EOF
  PYTHON_CPUS_RESOLVED=6.0 run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 1 ]
  grep -q "target=28 rep=none \[FATAL\] \[recorded-settings\]: python-service cpus resolves to '6.0'" "${RUN_DIR}/openloop_failures_log.txt"
  : > "${RUN_DIR}/openloop_failures_log.txt"
  JVM_OPTS_RESOLVED="-XX:+UseParallelGC" run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 1 ]
  grep -q "JAVA_TOOL_OPTIONS resolves to '-XX:+UseParallelGC'" "${RUN_DIR}/openloop_failures_log.txt"
  [ ! -e "${RUN_DIR}/run_failures_log.txt" ]
}

@test "run-openloop.sh: a quota written differently but equal numerically is accepted" {
  openloop_harness <<'EOF'
load_recorded_settings
verify_recorded_settings
echo ok
EOF
  PYTHON_CPUS_RESOLVED=4 run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- run-openloop.sh: repetitions ---

@test "run-openloop.sh: each rep restarts the stack and runs the suite's guards and both gated warm-up passes" {
  openloop_harness <<'EOF'
load_recorded_settings
COOLDOWN_S=10; OPENLOOP_REPS=2; RATES=(40 50)
OPENLOOP_DURATION=2m OPENLOOP_PRE_ALLOCATED_VUS=64 OPENLOOP_MAX_VUS=128 OPENLOOP_PHASE=openloop-check
WARMUP_ENV_ARGS=("WARMUP_TARGETS=28"); WARMUP_MAXVUS_ENV_ARGS=("WARMUP_TARGETS=28")
restart_stack() { echo "step restart_stack"; }
for rep in 1 2; do openloop_rep "$rep"; done
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  rep1=$(sed -n '/Open-loop repetition 1\//,/Open-loop repetition 2\//p' <<< "$output" | grep -o '^step [a-z_]*' | cut -d' ' -f2 | paste -sd' ' -)
  [ "$rep1" = "record_env_sample check_power_state restart_stack wait_for_ready verify_cpu_pinning verify_jvm_flag_pins verify_tiers converge_warmup log_warmup_verdict verify_tiers_runtime verify_jvm_thread_pins sleep converge_warmup log_warmup_verdict sleep check_thermal_safety run_cell finalize_result sleep check_thermal_safety run_cell finalize_result sleep record_env_sample archive_gc_log" ]
  [ "$(grep -c '^step restart_stack' <<< "$output")" -eq 2 ]
  [[ "$output" == *"step converge_warmup openloop-warmup_28_rep1 WARMUP_TARGETS=28 REP=1"* ]]
  [[ "$output" == *"step converge_warmup openloop-warmup_28_maxvus_rep2 WARMUP_TARGETS=28 WARMUP_VUS=48 REP=2"* ]]
  for cell in openloop_28_rate40_rep1 openloop_28_rate50_rep1 openloop_28_rate40_rep2 openloop_28_rate50_rep2; do
    [[ "$output" == *"step run_cell ${cell}"* ]]
    [[ "$output" == *"step finalize_result ${cell}.json"* ]]
  done
  [ "$(grep -c '^step sleep 10$' <<< "$output")" -eq 8 ]
  [ "$(grep -c '^openloop_order rep=' "${RUN_DIR}/openloop_log.txt")" -eq 2 ]
}

@test "run-openloop.sh: the rate order is shuffled per rep" {
  openloop_harness <<'EOF'
load_recorded_settings
COOLDOWN_S=0; OPENLOOP_REPS=12; RATES=(10 20 30 40)
OPENLOOP_DURATION=1s OPENLOOP_PRE_ALLOCATED_VUS=1 OPENLOOP_MAX_VUS=1 OPENLOOP_PHASE=openloop-check
WARMUP_ENV_ARGS=(); WARMUP_MAXVUS_ENV_ARGS=()
restart_stack() { :; }
for rep in $(seq 1 12); do openloop_rep "$rep" > /dev/null; done
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  orders=$(grep -o 'rate_order=[0-9,]*' "${RUN_DIR}/openloop_log.txt")
  [ "$(wc -l <<< "$orders")" -eq 12 ]
  # Every rep runs each rate once; 12 identical orders of 4 rates would be a 1-in-24^11 draw.
  while read -r o; do [ "$(tr ',' '\n' <<< "${o#rate_order=}" | sort -n | paste -sd, -)" = "10,20,30,40" ]; done <<< "$orders"
  [ "$(sort -u <<< "$orders" | wc -l)" -gt 1 ]
}

@test "run-openloop.sh: warm-up is gated unless the suite's fixed-iteration override is set" {
  block=$(sed -n '/^WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=/,/^case " mock calibration/p' "$OPENLOOP_SH" | sed '$d')
  run bash -c "OPENLOOP_TARGET=28; ${block}
echo \"\${WARMUP_ENV_ARGS[*]} | \${WARMUP_MAXVUS_ENV_ARGS[*]}\""
  [ "$output" = "WARMUP_TARGETS=28 | WARMUP_TARGETS=28" ]
  run bash -c "OPENLOOP_TARGET=28; WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20; ${block}
echo \"\${WARMUP_ENV_ARGS[*]} | \${WARMUP_MAXVUS_ENV_ARGS[*]}\""
  [ "$output" = "WARMUP_TARGETS=28 WARMUP_ITERATIONS_PER_TARGET=20 | WARMUP_TARGETS=28 WARMUP_ITERATIONS_PER_TARGET=20" ]
}

@test "run-openloop.sh: startup runs the recorded-settings, topology and cpuset guards before the first rep" {
  settings=$(grep -n '^verify_recorded_settings$' "$OPENLOOP_SH" | cut -d: -f1)
  smt=$(grep -n '^verify_smt_isolation "$PYTHON_CPUSET" "$JAVA_CPUSET" "$K6_CPUSET"$' "$OPENLOOP_SH" | cut -d: -f1)
  trap_line=$(grep -n '^trap _log_uncaught_exit EXIT$' "$OPENLOOP_SH" | cut -d: -f1)
  loop=$(grep -n '^for rep in $(seq 1 "$OPENLOOP_REPS"); do$' "$OPENLOOP_SH" | cut -d: -f1)
  [ -n "$settings" ] && [ -n "$smt" ] && [ "$trap_line" -lt "$settings" ] && [ "$settings" -lt "$smt" ] && [ "$smt" -lt "$loop" ]
  [ "$(grep -c '^verify_service_cpuset "openloop startup"' "$OPENLOOP_SH")" -eq 3 ]
  grep -q '^\. lib/suite-stack.sh$' "$OPENLOOP_SH"
}

# --- run-openloop.sh: failures stay out of the suite's failures log ---

@test "run-openloop.sh: an abort writes one tagged line to openloop_failures_log.txt and none to run_failures_log.txt" {
  : > "${RUN_DIR}/run_failures_log.txt"
  openloop_harness <<'EOF'
FAILURES_AT_START=0
trap _log_uncaught_exit EXIT
CURRENT_REP=3
abort_suite "[cpu-pin] openloop rep=3" "live cpuset" "differs."
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c . "${RUN_DIR}/openloop_failures_log.txt")" -eq 1 ]
  grep -q " target=28 rep=3 \[FATAL\] \[cpu-pin\] openloop rep=3: live cpuset differs\.$" "${RUN_DIR}/openloop_failures_log.txt"
  [ ! -s "${RUN_DIR}/run_failures_log.txt" ]
  grep -q '^docker compose -f fake-compose.yml down' "$DOCKER_LOG"
  ! grep -v '^ *#' "$OPENLOOP_SH" | grep -q 'run_failures_log'
}

@test "run-openloop.sh: an exit no check logged is recorded by the catch-all" {
  openloop_harness <<'EOF'
FAILURES_AT_START=0
trap _log_uncaught_exit EXIT
CURRENT_REP=2
false
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 1 ]
  grep -q "target=28 rep=2 \[FATAL\] \[uncaught\] open-loop check aborted with status 1" "${RUN_DIR}/openloop_failures_log.txt"
}

@test "run-openloop.sh: a new invocation archives only its own target's earlier cells and failure lines" {
  touch "${RUN_DIR}/openloop_28_rate50_rep1.json.gz" "${RUN_DIR}/openloop_28_rate50.json.gz" \
        "${RUN_DIR}/openloop-warmup_28_rep1.json.gz" "${RUN_DIR}/openloop_5_rate90_rep1.json.gz"
  printf 'ts target=28 rep=1 [FATAL] x\nts target=5 rep=2 [FATAL] y\n' > "${RUN_DIR}/openloop_failures_log.txt"
  openloop_harness <<'EOF'
archive_previous_openloop
EOF
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [ -e "${RUN_DIR}/openloop_5_rate90_rep1.json.gz" ]
  [ ! -e "${RUN_DIR}/openloop_28_rate50_rep1.json.gz" ] && [ ! -e "${RUN_DIR}/openloop_28_rate50.json.gz" ]
  archived=$(ls -d "${RUN_DIR}"/archive/openloop_*)
  [ -e "${archived}/openloop_28_rate50_rep1.json.gz" ] && [ -e "${archived}/openloop-warmup_28_rep1.json.gz" ]
  [ "$(cat "${archived}/openloop_failures_log.txt")" = "ts target=28 rep=1 [FATAL] x" ]
  [ "$(cat "${RUN_DIR}/openloop_failures_log.txt")" = "ts target=5 rep=2 [FATAL] y" ]
}

@test "run-openloop.sh: a non-integer OPENLOOP_REPS is rejected before the stack is touched" {
  run env OPENLOOP_REPS=many "$OPENLOOP_SH" "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OPENLOOP_REPS must be a positive integer, got 'many'"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

# --- run-predict-composition.sh, whole script against a stubbed docker ---

# Skips unless the live host passes require_prepared_host, which the script checks first.
need_prepared_host() {
  local problems
  problems=$(bash -c ". '${LT_DIR}/lib/host-provenance.sh'; . '${LT_DIR}/lib/power-state.sh'; power_state_problems off")
  [ -z "$problems" ] || skip "host not in a measurement power state: ${problems}"
}

# docker stub for the composition script: `ps` lists RUNNING_SERVICES, the image is
# built, and `compose run` writes the rep file predict_composition.py would (failing on
# FAIL_REP) from the arguments it was given.
composition_docker() {
  cat > "${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_LOG"
case "$1" in
  ps) for s in ${RUNNING_SERVICES:-}; do echo "$s ${s%%-*}"; done; exit 0 ;;
  image) echo "sha256:abc"; exit 0 ;;
esac
case " $* " in
  *" config --images "*) echo "repo-python-service"; exit 0 ;;
  *" run --rm "*)
    out="" rep="" tiers="" quota="" outdir=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        --out) out="$a" ;; --rep) rep="$a" ;; --tiers) tiers="$a" ;; --expect-cpu-quota) quota="$a" ;;
        -v) case "$a" in *:/out) outdir="${a%:/out}" ;; esac ;;
      esac
      prev="$a"
    done
    [ "$rep" = "${FAIL_REP:-}" ] && exit 1
    python3 - "${outdir}${out#/out}" "$rep" "$tiers" "$quota" <<'PY'
import json, sys
path, rep, tiers, quota = sys.argv[1], int(sys.argv[2]), [int(t) for t in sys.argv[3].split(",")], float(sys.argv[4])
tier = lambda t: {"tier": t, "n": 10, "total_ms": {"median": 2.0, "n": 10}, "traversal_ms": {"median": 0.1, "n": 10}}
json.dump({"schema": 2, "kind": "rep", "rep": rep, "tier_order": tiers, "image_id": "sha256:abc",
           "n_calls": 10, "warmup_calls": 1, "feature_seed": 1, "amount": 100.0, "clock": "c",
           "numeric_thread_env": {}, "versions": {}, "cpu_affinity": "0-3",
           "cpu_quota": {"status": "verified", "expected": quota, "observed": quota},
           "tiers": [tier(t) for t in tiers]}, open(path, "w"))
PY
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "${WORKDIR}/bin/docker"
}

@test "run-predict-composition.sh: a suite run without a recorded Python CPU quota is refused" {
  echo '{"cores_used_by_suite": {"python_service_cpuset": "0-1"}}' > "$RUN_DIR/run_metadata.json"
  run "$COMPOSITION_SH" "$RUN_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded no Python CPU quota"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

@test "run-predict-composition.sh: reps run in fresh containers with shuffled tiers and merge into schema 2" {
  need_prepared_host
  composition_docker
  run env COMPOSITION_REPS=8 COMPOSITION_COOLDOWN_S=0 COMPOSITION_N=10 COMPOSITION_WARMUP=1 "$COMPOSITION_SH" "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$(grep -c ' run --rm --no-deps -T ' "$DOCKER_LOG")" -eq 8 ]
  grep -q -- '--expect-cpuset 0-3 --expect-cpu-quota 4.0' "$DOCKER_LOG"
  run python3 - "${RUN_DIR}/predict_composition.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
orders = [tuple(x["tier_order"]) for x in r["reps"]]
assert r["schema"] == 2 and r["n_reps"] == 8 and [x["rep"] for x in r["reps"]] == list(range(1, 9))
assert all(sorted(o) == [5, 10, 20, 28] for o in orders)
assert len(set(orders)) > 1, orders
assert all(x["cpu_quota"]["expected"] == 4.0 for x in r["reps"])
print("ok")
EOF
  [ "$output" = "ok" ]
  [ ! -s "${RUN_DIR}/composition_failures_log.txt" ]
  [ ! -e "${RUN_DIR}/run_failures_log.txt" ]
  [ "$(grep -c 'label=composition_rep[0-9]*_start' "${RUN_DIR}/composition_env_trace_log.txt")" -eq 8 ]
  [ "$(grep -c '^thermal_check .*label=composition rep=' "${RUN_DIR}/composition_env_trace_log.txt")" -eq 8 ]
}

@test "run-predict-composition.sh: a running measured stack is refused into composition_failures_log.txt" {
  need_prepared_host
  composition_docker
  run env RUNNING_SERVICES="python-service" "$COMPOSITION_SH" "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q 'rep=none \[FATAL\] \[stack\]: the measured stack is running (python)' "${RUN_DIR}/composition_failures_log.txt"
  ! grep -q ' run --rm ' "$DOCKER_LOG"
  [ ! -e "${RUN_DIR}/predict_composition.json" ] && [ ! -e "${RUN_DIR}/run_failures_log.txt" ]
}

@test "run-predict-composition.sh: a failed rep aborts with its rep number and leaves no merged file" {
  need_prepared_host
  composition_docker
  run env COMPOSITION_REPS=3 COMPOSITION_COOLDOWN_S=0 FAIL_REP=2 "$COMPOSITION_SH" "$RUN_DIR"
  [ "$status" -eq 1 ]
  grep -q 'rep=2 \[FATAL\] \[composition\] rep=2: predict_composition.py exited non-zero' "${RUN_DIR}/composition_failures_log.txt"
  [ "$(grep -c . "${RUN_DIR}/composition_failures_log.txt")" -eq 1 ]
  [ ! -e "${RUN_DIR}/predict_composition.json" ] && [ ! -e "${RUN_DIR}/run_failures_log.txt" ]
}

# --- smoke test wiring ---

@test "run-smoke-test.sh: one open-loop rep and one composition rep, checked for schema 2 and then deleted" {
  smoke="${LT_DIR}/run-smoke-test.sh"
  grep -q '^OPENLOOP_REPS=1 WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \\$' "$smoke"
  grep -q '^SMOKE_FILE="${SUITE_DIR}/openloop_28_rate5000_rep1.json.gz"$' "$smoke"
  grep -q '^COMPOSITION_REPS=1 COMPOSITION_N=50 COMPOSITION_WARMUP=5 ./run-predict-composition.sh "$SUITE_DIR"$' "$smoke"
  grep -q 'report.get("schema") != 2' "$smoke"
  grep -q '^rm -f "$COMPOSITION_FILE"$' "$smoke"
  grep -q '^rm -rf "${SUITE_DIR}/predict_composition_reps"$' "$smoke"
  composition=$(grep -n 'run-predict-composition.sh' "$smoke" | head -1 | cut -d: -f1)
  ablation=$(grep -n '^\./run-ablation.sh$' "$smoke" | cut -d: -f1)
  [ "$composition" -lt "$ablation" ]
}

@test "run-all.sh: the stack is stopped before the composition check, whose failure still continues the chain" {
  body=$(sed -n '/^if runs composition/,/^fi$/p' "${LT_DIR}/run-all.sh")
  [[ "$body" == *"docker compose -f ../docker-compose.yml down"* ]]
  [[ "$body" == *"FAILED (see composition.log); continuing"* ]]
}
