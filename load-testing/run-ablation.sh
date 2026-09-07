#!/usr/bin/env bash
set -euo pipefail

# Isolates the drivers of thread-dispatch time at VUS=64 / TARGET=28 across four arms:
# thread_limiter, cpuset, workers, and workers with aggregate token capacity held constant.
# python-service takes interleaved even physical cores so it stays SMT-disjoint from Java and k6.

cd "$(dirname "${BASH_SOURCE[0]}")"

for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- see README Limitations on cpu-pin verification under WSL2." >&2
fi

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR"

# Separate log files from run-suite.sh's, so an ablation run never trips
# analyze-results.py's hard-fail-on-any-failures-log-entry check for the main
# suite's own dataset.
ORDER_LOG="${RESULTS_DIR}/ablation_run_order_log.txt"
: > "$ORDER_LOG"
METADATA_FILE="${RESULTS_DIR}/ablation_run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/ablation_run_failures_log.txt"
: > "$FAILURES_LOG"
CPU_PIN_LOG="${RESULTS_DIR}/ablation_cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"

ABLATION_TARGET="${ABLATION_TARGET_OVERRIDE:-28}"
ABLATION_VUS="${ABLATION_VUS_OVERRIDE:-64}"
ITERATIONS_PER_VU="${ABLATION_ITERATIONS_PER_VU_OVERRIDE:-100}"
# Sets default replicate count to n=7 per arm to ensure statistical power for Mann-Whitney tests and bootstrap CIs.
REPS_ABLATION="${REPS_ABLATION_OVERRIDE:-7}"
COOLDOWN_S=10
ANYIO_DEFAULT_TOKENS=40
EXPECTED_TIERS="5,10,20,28"
# Matches docker-compose.yml's default, so every arm's control cell is the same
# configuration E1 and E2 measured. An ablation run at a different worker count would
# characterise a service the main suite never benchmarked.
CONTROL_WORKERS=3
CONTROL_CPUSET="0-1,4-5,8-9"
CONTROL_CPUS="6.0"

# Sized off the ablation's own VUS so the Java outbound pool is never the
# bottleneck under test. Consumed by docker-compose.yml.
export PYTHON_SERVICE_MAX_CONNECTIONS=$((ABLATION_VUS * 2))

ENV_TRACE_LOG="${RESULTS_DIR}/ablation_env_trace_log.txt"
: > "$ENV_TRACE_LOG"

# Sets transaction-service cpuset to odd physical cores (1, 3) to align with docker-compose.yml and SMT validation.
JAVA_CPUSET="2-3,6-7"
# Physical cores 5, 7 (CPUs 10-11, 14-15) -- fully disjoint from both services.
K6_CPUSET="10-11,14-15"

# arm:value:cpuset:cpus:workers:tokens
# Each arm holds the other mechanisms at the control values above and sweeps one.
# python-service takes whole physical cores (2, 6 or 8 logical CPUs); verify_smt_isolation
# re-checks disjointness per cell because the cpuset arm changes it.
#
# The thread limiter is per process, so the workers arm varies GIL count and aggregate
# token capacity together (3 workers = 3 x 40 tokens). workers_token_matched repeats
# the endpoints with tokens scaled to hold the aggregate near 40, which separates the
# two explanations.
CELLS=(${ABLATION_CELLS_OVERRIDE:-
  "thread_limiter:40:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:40"
  "thread_limiter:64:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:64"
  "thread_limiter:128:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:128"
  "cpuset:0-1:0-1:2.0:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:${CONTROL_CPUSET}:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:0-1,4-5,8-9,12-13:0-1,4-5,8-9,12-13:8.0:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "workers:1:${CONTROL_CPUSET}:${CONTROL_CPUS}:1:${ANYIO_DEFAULT_TOKENS}"
  "workers:2:${CONTROL_CPUSET}:${CONTROL_CPUS}:2:${ANYIO_DEFAULT_TOKENS}"
  "workers:3:${CONTROL_CPUSET}:${CONTROL_CPUS}:3:${ANYIO_DEFAULT_TOKENS}"
  "workers_token_matched:1:${CONTROL_CPUSET}:${CONTROL_CPUS}:1:40"
  "workers_token_matched:3:${CONTROL_CPUSET}:${CONTROL_CPUS}:3:13"
})

# Unset by default -- warm-up.js's own 3000 default applies for the full ablation.
# Set for a reduced-scale run so warm-up doesn't dwarf it.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"
WARMUP_ENV_ARGS=(WARMUP_TARGETS="$ABLATION_TARGET" WARMUP_VUS="$ABLATION_VUS")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi

capture_run_metadata() {
  local timestamp git_commit git_dirty cpu_model cpu_count total_mem_kb
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v git >/dev/null 2>&1 && git -C .. rev-parse HEAD >/dev/null 2>&1; then
    git_commit=$(git -C .. rev-parse HEAD)
    git_dirty=$([ -n "$(git -C .. status --porcelain 2>/dev/null)" ] && echo "true" || echo "false")
  else
    git_commit="unknown"; git_dirty="unknown"
  fi
  cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
  cpu_count=$(nproc 2>/dev/null || echo "unknown")
  total_mem_kb=$(grep -m1 "MemTotal" /proc/meminfo 2>/dev/null | grep -o '[0-9]*' || echo "unknown")

  # Reads the control cpuset for each service from the resolved compose config.
  # python-service's cpuset varies per cell during the ablation run; this
  # records the baseline/control value (0-2) written in docker-compose.yml.
  local resolved_config
  resolved_config=$(docker compose -f "$COMPOSE_FILE" config 2>/dev/null || echo "")

  extract_cpuset() {
    printf '%s\n' "$resolved_config" | awk -v svc="  ${1}:" '
      $0 == svc { in_svc=1; next }
      in_svc && /^  [a-zA-Z0-9_-]+:$/ { in_svc=0 }
      in_svc && /^ +cpuset:/ { sub(/^ +cpuset: */, ""); gsub(/"/, ""); print; exit }
    '
  }

  local py_cpuset java_cpuset k6_cpuset
  py_cpuset=$(extract_cpuset "python-service")
  java_cpuset=$(extract_cpuset "transaction-service")
  k6_cpuset=$(extract_cpuset "k6")

  local py_cores java_cores k6_cores total_pinned_cores
  py_cores=$(count_cpuset_cores "${py_cpuset:-}")
  java_cores=$(count_cpuset_cores "${java_cpuset:-}")
  k6_cores=$(count_cpuset_cores "${k6_cpuset:-}")
  total_pinned_cores=$((py_cores + java_cores + k6_cores))

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "${timestamp}",
  "wsl2_detected": "${IS_WSL2}",
  "git_commit": "${git_commit}",
  "git_dirty": "${git_dirty}",
  "cpu_model": "${cpu_model}",
  "cpu_count": "${cpu_count}",
  "total_mem_kb": "${total_mem_kb}",
  "cores_used_by_suite": {
    "python_service_cpuset": "${py_cpuset:-unknown}",
    "python_service_cores": ${py_cores},
    "transaction_service_cpuset": "${java_cpuset:-unknown}",
    "transaction_service_cores": ${java_cores},
    "k6_cpuset": "${k6_cpuset:-unknown}",
    "k6_cores": ${k6_cores},
    "total_pinned_cores": ${total_pinned_cores},
    "host_cores_available": "${cpu_count}",
    "note": "python_service_cpuset reflects the docker-compose.yml control value; the cpuset arm sweeps other values at runtime"
  },
  "ablation_config": {
    "target": "${ABLATION_TARGET}",
    "vus": ${ABLATION_VUS},
    "iterations_per_vu": ${ITERATIONS_PER_VU},
    "reps": ${REPS_ABLATION},
    "anyio_default_tokens": ${ANYIO_DEFAULT_TOKENS},
    "cells": [$(printf '"%s",' "${CELLS[@]}" | sed 's/,$//')]
  }
}
EOF
  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} (pinned: ${total_pinned_cores}) git=${git_commit:0:12} wsl2=${IS_WSL2}"
}

abort_suite() {
  local label="$1"; shift
  echo "" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] ${label}: $*" | tee -a "$FAILURES_LOG"
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

count_cpuset_cores() {
  local cpuset="$1" total=0 part lo hi
  IFS=',' read -ra _parts <<< "$cpuset"
  for part in "${_parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"; hi="${part#*-}"
      total=$(( total + (hi - lo + 1) ))
    elif [ -n "$part" ]; then
      total=$(( total + 1 ))
    fi
  done
  echo "$total"
}

read_live_cpuset() {
  docker exec "$1" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}

expand_cpuset() {
  local part lo hi i
  IFS=',' read -ra _parts <<< "$1"
  for part in "${_parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"; hi="${part#*-}"
      for ((i = lo; i <= hi; i++)); do echo "$i"; done
    elif [ -n "$part" ]; then
      echo "$part"
    fi
  done
}

# Lowest-numbered member of a logical CPU's SMT sibling list -- a stable key for
# the physical core behind it.
core_key_of_cpu() {
  local siblings="/sys/devices/system/cpu/cpu${1}/topology/thread_siblings_list"
  [ -r "$siblings" ] || return 0
  sed 's/[,-].*//' "$siblings" | tr -d ' \n'
}

core_keys_of_cpuset() {
  local cpu key
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    key=$(core_key_of_cpu "$cpu")
    [ -n "$key" ] && echo "$key"
  done < <(expand_cpuset "$1") | sort -un | paste -sd, -
}

# Validates python-service cpusets per cell before load runs to prevent SMT sibling contention.
# Ensures widening CPU allocation measures true hardware scaling rather than shared-core contention.
verify_smt_isolation() {
  local label="$1" py_cpuset="$2"

  if [ ! -r /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]; then
    echo "  [smt] ${label}: WARNING -- SMT topology not exposed (common under WSL2);" \
         "physical-core disjointness is UNVERIFIED for this cell."
    echo "smt_check label=${label} status=unverifiable reason=topology_not_exposed" >> "$CPU_PIN_LOG"
    return 0
  fi

  local py_keys java_keys k6_keys shared
  py_keys=$(core_keys_of_cpuset "$py_cpuset")
  java_keys=$(core_keys_of_cpuset "$JAVA_CPUSET")
  k6_keys=$(core_keys_of_cpuset "$K6_CPUSET")

  echo "  [smt] ${label}: physical cores python(${py_keys:-EMPTY}) java(${java_keys:-EMPTY}) k6(${k6_keys:-EMPTY})"
  echo "smt_check label=${label} python_cores=${py_keys:-EMPTY} java_cores=${java_keys:-EMPTY} k6_cores=${k6_keys:-EMPTY}" \
    >> "$CPU_PIN_LOG"

  shared=$(comm -12 \
    <(tr ',' '\n' <<< "$py_keys" | sort -u) \
    <(cat <(tr ',' '\n' <<< "$java_keys") <(tr ',' '\n' <<< "$k6_keys") | sort -u) | paste -sd, -)

  if [ -n "$shared" ]; then
    abort_suite "[smt] ${label}" "python-service's cpuset (${py_cpuset}) shares physical core(s) ${shared}" \
      "with transaction-service (${JAVA_CPUSET}) and/or k6 (${K6_CPUSET}) via SMT siblings. The cpuset" \
      "arm would then vary contention rather than core count, so its result would be uninterpretable." \
      "Pick cpuset values whose thread_siblings_list entries are disjoint from ${JAVA_CPUSET} and ${K6_CPUSET}" \
      "(inspect with: cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list)."
  fi
}

record_env_sample() {
  local governor freqs
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
  freqs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | paste -sd, -)
  echo "env_sample label=${1} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) governor=${governor} freqs_khz=${freqs:-unavailable}" \
    >> "$ENV_TRACE_LOG"
}

# Trimmed from run-suite.sh's verify_cpu_pinning: python-service's cpuset
# varies per cell here, so this compares live-vs-requested only (still the
# check that matters -- whether the cgroup driver honored what was asked).
verify_cpu_pinning() {
  local label="$1"
  local py_container py_requested py_live
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  [ -z "$py_container" ] && abort_suite "[cpu-pin] ${label}" "could not resolve python-service container ID."
  py_requested=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$py_container" 2>/dev/null || echo "")
  py_live=$(read_live_cpuset "$py_container")
  echo "  [cpu-pin] ${label}: requested(${py_requested:-EMPTY}) live(${py_live:-EMPTY})"
  echo "cpu_pin_check label=${label} python_requested=${py_requested:-EMPTY} python_live=${py_live:-EMPTY}" >> "$CPU_PIN_LOG"
  if [ -z "$py_live" ] || [ "$py_live" != "$py_requested" ]; then
    abort_suite "[cpu-pin] ${label}" "live cpuset (${py_live:-EMPTY}) does not match requested (${py_requested:-EMPTY})."
  fi
}

verify_tiers_and_limiter() {
  local label="$1" expected_tokens="$2"
  local health_json loaded_tiers all_verified live_tokens thread_env
  health_json=$(curl -s http://localhost:8000/health 2>/dev/null || echo "")
  [ -z "$health_json" ] && abort_suite "[health] ${label}" "could not reach python-service's /health."

  loaded_tiers=$(echo "$health_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(",".join(sorted((str(t) for t in d.get("loadedTiers", [])), key=int)))
except Exception:
    print("")
')
  all_verified=$(echo "$health_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("true" if all(d.get("nJobsVerified", {}).values()) else "false")
except Exception:
    print("false")
')
  live_tokens=$(echo "$health_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("threadLimiterTokens", ""))
except Exception:
    print("")
')

  thread_env=$(echo "$health_json" | python3 -c '
import json, sys
try:
    env = json.load(sys.stdin).get("numericThreadEnv", {})
    print(",".join(f"{k}={v}" for k, v in sorted(env.items())))
except Exception:
    print("")
')

  echo "  [health] ${label}: tiers(${loaded_tiers:-EMPTY}) n_jobs_verified(${all_verified}) thread_limiter_tokens(${live_tokens:-EMPTY} expected ${expected_tokens})"
  echo "cpu_pin_check label=${label} tiers_loaded=${loaded_tiers:-EMPTY} tiers_expected=${EXPECTED_TIERS} n_jobs_verified=${all_verified} numeric_thread_env=${thread_env:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ "$loaded_tiers" != "$EXPECTED_TIERS" ]; then
    abort_suite "[health] ${label}" "loadedTiers (${loaded_tiers:-EMPTY}) != expected (${EXPECTED_TIERS})."
  elif [ "$all_verified" != "true" ]; then
    abort_suite "[health] ${label}" "nJobsVerified reports at least one tier without n_jobs=1."
  elif [ "$live_tokens" != "$expected_tokens" ]; then
    abort_suite "[health] ${label}" "threadLimiterTokens (${live_tokens:-EMPTY}) != expected (${expected_tokens}) -- override did not take effect."
  fi

  # Matches run-suite.sh: n_jobs=1 alone does not constrain the OpenMP layer beneath it.
  case "$thread_env" in
    *OMP_NUM_THREADS=1*) ;;
    *) abort_suite "[health] ${label}" "OMP_NUM_THREADS is not pinned to 1 (${thread_env:-EMPTY})" \
         "-- numeric libraries may spawn threads outside the measured cpuset." ;;
  esac
}

# Re-reads n_jobs as observed after real inference; run post-warm-up, once the
# target tier has served traffic. Mirrors run-suite.sh's check of the same name.
verify_tiers_runtime() {
  local label="$1" runtime_state
  runtime_state=$(curl -s http://localhost:8000/health 2>/dev/null | python3 -c '
import json, sys
try:
    verified = json.load(sys.stdin).get("nJobsRuntimeVerified", {})
except Exception:
    print("unreadable")
else:
    failed = [tier for tier, ok in verified.items() if ok is False]
    print("failed:" + ",".join(failed) if failed else "ok")
')
  echo "  [health] ${label}: n_jobs_runtime(${runtime_state})"
  echo "cpu_pin_check label=${label} n_jobs_runtime=${runtime_state}" >> "$CPU_PIN_LOG"
  if [ "$runtime_state" != "ok" ]; then
    abort_suite "[health] ${label}" "nJobsRuntimeVerified reports ${runtime_state} after serving inference."
  fi
}

restart_stack() {
  local cpuset="$1" cpus="$2" workers="$3" tokens="$4"
  echo "  [restart] cpuset=${cpuset} cpus=${cpus} workers=${workers} thread_limiter_tokens=${tokens}"
  docker compose -f "$COMPOSE_FILE" down
  PYTHON_CPUSET="$cpuset" PYTHON_CPUS="$cpus" UVICORN_WORKERS="$workers" THREAD_LIMITER_TOKENS="$tokens" \
    docker compose -f "$COMPOSE_FILE" up -d --wait
}

wait_for_ready() {
  local url="http://localhost:8080/api/v1/transactions"
  for i in $(seq 1 60); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
      2>/dev/null) || status="000"
    [ "$status" = "200" ] && { echo "  [ready] after ${i} attempt(s)."; return 0; }
    sleep 2
  done
  # Routed through abort_suite so a readiness timeout reaches the failures log that
  # analyze-ablation.py gates on, rather than exiting with that log still clean.
  abort_suite "[ready]" "transaction-service did not respond 200 within 60 attempts" \
    "(last status ${status:-none}) -- the stack never became ready for this cell."
}

check_oom_killed() {
  local label="$1" py_container java_container py_oom java_oom
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  py_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$py_container" 2>/dev/null || echo "unknown")
  java_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$java_container" 2>/dev/null || echo "unknown")
  if [ "$py_oom" = "true" ] || [ "$java_oom" = "true" ]; then
    abort_suite "[cell] ${label}" "OOM-killed: python=${py_oom} java=${java_oom}"
  fi
}

k6_run() {
  local script="$1"; shift
  local env_flags=()
  while [ "$1" != "--" ]; do env_flags+=("-e" "$1"); shift; done
  shift
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    "${env_flags[@]}" k6 run "/scripts/${script}" "$@"
}

shuffled() { printf '%s\n' "$@" | shuf | tr '\n' ' '; }

capture_run_metadata

echo "[*] Ablation: ${#CELLS[@]} cells x ${REPS_ABLATION} reps, target=${ABLATION_TARGET} vus=${ABLATION_VUS}"
for rep in $(seq 1 "$REPS_ABLATION"); do
  echo "[*] --- Ablation repetition ${rep}/${REPS_ABLATION} ---"
  read -ra CELLS_THIS_REP <<< "$(shuffled "${CELLS[@]}")"
  echo "ablation rep=${rep} cell_order=${CELLS_THIS_REP[*]}" >> "$ORDER_LOG"

  for cell in "${CELLS_THIS_REP[@]}"; do
    IFS=':' read -r arm value cpuset cpus workers tokens <<< "$cell"
    label="arm=${arm} value=${value} rep=${rep}"
    echo "  -> ${label}"

    record_env_sample "${arm}_${value}_rep${rep}_start"
    verify_smt_isolation "$label" "$cpuset"
    restart_stack "$cpuset" "$cpus" "$workers" "$tokens"
    wait_for_ready
    verify_cpu_pinning "$label"
    verify_tiers_and_limiter "$label" "$tokens"

    echo "  [warm-up] VUS=${ABLATION_VUS}..."
    k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" -- \
      --out "json=/results/ablation_warmup_${arm}_${value}_rep${rep}.json"
    verify_tiers_runtime "$label"
    sleep "$COOLDOWN_S"

    if ! k6_run run-target.js \
      TARGET="$ABLATION_TARGET" VUS="$ABLATION_VUS" ITERATIONS_PER_VU="$ITERATIONS_PER_VU" \
      PHASE=ablation REP="$rep" ARM="$arm" ARM_VALUE="$value" -- \
      --out "json=/results/ablation_${arm}_${value}_rep${rep}.json"
    then
      abort_suite "[cell] ${label}" "k6 exited non-zero."
    fi
    check_oom_killed "$label"
    record_env_sample "${arm}_${value}_rep${rep}_end"
    sleep "$COOLDOWN_S"
  done
done

docker compose -f "$COMPOSE_FILE" down
echo "[+] Ablation complete. Raw results in ${RESULTS_DIR}/ablation_*.json"
echo "    SMT topology and pinning checks logged to ${CPU_PIN_LOG}"
echo "    Per-cell governor/frequency samples logged to ${ENV_TRACE_LOG}"
echo "    Run: python3 ../analysis/analyze-ablation.py"