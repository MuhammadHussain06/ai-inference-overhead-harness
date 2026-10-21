#!/usr/bin/env bash
# Open-loop validity check against one run-suite.sh run: constant-arrival-rate cells for
# one target, written into that run's directory so analyze-results.py's table 7 compares
# them with the same run's closed-loop scan.
#
# Usage: ./run-openloop.sh [SUITE_RUN_DIR]     (default: this host's latest suite run)
#
# Rates are fractions of the target's closed-loop throughput at the run's highest scan
# concurrency (OPENLOOP_FRACTIONS, default "1.0 0.8"), or explicit via OPENLOOP_RATES.
# The cells run under the suite's controls (lib/suite-stack.sh): the stack starts on the
# cpusets, CPU quotas, worker count and thread-limiter tokens the suite run recorded, in
# the power state it recorded; each of OPENLOOP_REPS repetitions restarts the stack, runs
# the suite's per-rep guards and gated warm-up, and shuffles the rate order; every cell
# runs after a thermal check, between power checks, under the clock and placement samplers.
# Aborts go to openloop_failures_log.txt, never to the suite's run_failures_log.txt, so a
# failed check cannot invalidate the suite run it is compared with.
set -euo pipefail

# Same reason as run-suite.sh: a background docker compose must not read the terminal.
exec < /dev/null

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}." >&2
    exit 1
  fi
done
for _req_lib in lib/host-provenance.sh lib/power-state.sh lib/jvm-pins.sh lib/topology.sh lib/thermal.sh \
  lib/run-layout.sh lib/suite-stack.sh lib/k6_filter.py lib/openloop_rates.py lib/warmup_gate.py \
  lib/placement.py lib/cpufreq_sampler.py; do
  if [ ! -r "$_req_lib" ]; then
    echo "[!] Required helper not found: ${_req_lib}." >&2
    exit 1
  fi
done
. lib/host-provenance.sh
. lib/power-state.sh
. lib/jvm-pins.sh
. lib/topology.sh
. lib/thermal.sh
. lib/run-layout.sh
. lib/suite-stack.sh

for _sysfs_var in TOPO_SYSFS_ROOT THERMAL_SYSFS_ROOT POWER_SYSFS_ROOT; do
  if [ "${!_sysfs_var:-/sys}" != "/sys" ]; then
    echo "[!] ${_sysfs_var} is set to '${!_sysfs_var}'. Open-loop cells read the live host only;" >&2
    echo "    unset it before running." >&2
    exit 1
  fi
done

OPENLOOP_TARGET="${OPENLOOP_TARGET:-28}"
OPENLOOP_FRACTIONS="${OPENLOOP_FRACTIONS:-1.0 0.8}"
OPENLOOP_RATES="${OPENLOOP_RATES:-}"
OPENLOOP_DURATION="${OPENLOOP_DURATION:-2m}"
OPENLOOP_PRE_ALLOCATED_VUS="${OPENLOOP_PRE_ALLOCATED_VUS:-64}"
OPENLOOP_MAX_VUS="${OPENLOOP_MAX_VUS:-128}"
OPENLOOP_PHASE="${OPENLOOP_PHASE:-openloop-check}"
# The suite's REPS_SCAN default, so table 7's rep-level summaries rest on as many reps as
# the closed-loop cells they are compared with.
OPENLOOP_REPS="${OPENLOOP_REPS:-7}"
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"
# Only the metrics table 7 reads, and the error counters behind its N.
KEEP_METRICS="http_req_duration,http_req_blocked,dropped_iterations,request_http_error,request_timeout_error"
COMPOSE_FILE="../docker-compose.yml"
# python-service loads every tier in docker-compose.yml's FEATURE_TIERS; same value as
# run-suite.sh's.
EXPECTED_TIERS="5,10,20,28"
TARGETS=("$OPENLOOP_TARGET")
SMT_TOPOLOGY_STATUS="not checked"

# The suite's warm-up overrides, with the same effect: set, converge_warmup runs one
# fixed-iteration pass with no gate (the smoke test); unset, the gate decides.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"
WARMUP_MAX_DURATION_S_OVERRIDE="${WARMUP_MAX_DURATION_S_OVERRIDE:-}"
WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE:-$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}"
WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE="${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE:-$WARMUP_MAX_DURATION_S_OVERRIDE}"
WARMUP_ENV_ARGS=("WARMUP_TARGETS=${OPENLOOP_TARGET}")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAX_DURATION_S_OVERRIDE}")
fi
WARMUP_MAXVUS_ENV_ARGS=("WARMUP_TARGETS=${OPENLOOP_TARGET}")
if [ -n "$WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE}")
fi

case " mock calibration 5 10 20 28 " in
  *" ${OPENLOOP_TARGET} "*) ;;
  *) echo "[!] OPENLOOP_TARGET must be one of mock calibration 5 10 20 28, got '${OPENLOOP_TARGET}'." >&2; exit 1 ;;
esac
for _intvar in OPENLOOP_REPS OPENLOOP_PRE_ALLOCATED_VUS OPENLOOP_MAX_VUS THERMAL_WARN_C THERMAL_CRIT_C \
  THERMAL_COOLDOWN_S MAX_THERMAL_COOLDOWNS THERMAL_MAX_COOLDOWNS_EXTENDED; do
  if ! [[ "${!_intvar}" =~ ^[0-9]+$ ]] || [ "${!_intvar}" -lt 1 ]; then
    echo "[!] ${_intvar} must be a positive integer, got '${!_intvar}'." >&2
    exit 1
  fi
done

if [ "$#" -gt 0 ]; then
  RUN_DIR="$1"
else
  _runs=(../results/suite_"$(run_host_label)"_*)
  RUN_DIR="${_runs[-1]}"
fi
if [ ! -f "${RUN_DIR}/run_metadata.json" ]; then
  echo "[!] ${RUN_DIR} is not a run-suite.sh run directory." >&2
  exit 1
fi
RUN_DIR=$(cd "$RUN_DIR" && pwd)

# One field of the suite run's metadata by dotted path, empty when absent.
suite_metadata() {
  python3 - "${RUN_DIR}/run_metadata.json" "$1" <<'PYEOF'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)
PYEOF
}

# lib/suite-stack.sh writes cells, warm-up files and GC logs under RESULTS_DIR.
RESULTS_DIR="$RUN_DIR"
RAW_RESULTS_DIR="${RUN_DIR}/raw"
export RUN_RESULTS_DIR="$RUN_DIR"
OPENLOOP_LOG="${RUN_DIR}/openloop_log.txt"
ENV_TRACE_LOG="${RUN_DIR}/openloop_env_trace_log.txt"
CPU_PIN_LOG="${RUN_DIR}/openloop_cpu_pin_check_log.txt"
PLACEMENT_LOG="${RUN_DIR}/openloop_connection_placement_log.txt"
FAILURES_LOG="${RUN_DIR}/openloop_failures_log.txt"
CURRENT_REP="none"

# One line per abort, tagged with the target and rep, in openloop_failures_log.txt.
abort_suite() {
  local label="$1"; shift
  echo "  [FATAL] ${label}: $*" >&2
  echo "$(thermal_ts) target=${OPENLOOP_TARGET} rep=${CURRENT_REP} [FATAL] ${label}: $*" >> "$FAILURES_LOG"
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

# Catch-all for an exit no abort_suite() call logged. abort_suite inside $( ) exits only
# its subshell, so a line count rather than a flag tells whether this invocation logged.
_log_uncaught_exit() {
  local rc=$? n
  n=$(grep -c . "$FAILURES_LOG" 2>/dev/null || true)
  if [ "$rc" -ne 0 ] && [ "${n:-0}" -le "${FAILURES_AT_START:-0}" ]; then
    echo "$(thermal_ts) target=${OPENLOOP_TARGET} rep=${CURRENT_REP} [FATAL] [uncaught] open-loop check" \
         "aborted with status ${rc} before any check logged a reason." >> "$FAILURES_LOG"
  fi
  return 0
}

if [ -n "$OPENLOOP_RATES" ]; then
  read -ra RATES <<< "$OPENLOOP_RATES"
  PLATEAU="none"
  FRACTIONS="none"
else
  FRACTIONS="${OPENLOOP_FRACTIONS// /,}"
  if ! PLATEAU=$(python3 "${LIB_DIR}/openloop_rates.py" "$RUN_DIR" "$OPENLOOP_TARGET"); then
    echo "[!] Could not derive the plateau throughput of target ${OPENLOOP_TARGET} from ${RUN_DIR}." >&2
    exit 1
  fi
  RATES=()
  for f in $OPENLOOP_FRACTIONS; do
    RATES+=("$(awk -v p="${PLATEAU#* }" -v f="$f" 'BEGIN { printf "%d", p * f + 0.5 }')")
  done
fi
for r in "${RATES[@]}"; do
  if ! [[ "$r" =~ ^[1-9][0-9]*$ ]]; then
    echo "[!] Open-loop rate '${r}' is not a positive integer (requests per second)." >&2
    exit 1
  fi
done

# The open-loop cells are compared with this run's scan, so they must run in the power
# state it recorded.
SUITE_POWER_STATE=$(suite_metadata power_state.snapshot)
if [ -z "$SUITE_POWER_STATE" ]; then
  echo "[!] ${RUN_DIR} recorded no CPU power state, so open-loop cells cannot be matched to it." >&2
  exit 1
fi
require_prepared_host "$(suite_metadata power_state.turbo_required)"
if [ "$POWER_STATE_AT_START" != "$SUITE_POWER_STATE" ]; then
  echo "[!] The CPU power state differs from the one ${RUN_DIR} ran in:" >&2
  echo "      suite run: ${SUITE_POWER_STATE}" >&2
  echo "      now:       ${POWER_STATE_AT_START}" >&2
  exit 1
fi

# Exports the compose settings the suite run recorded, so every docker compose call below,
# including compose_service_value(), which the guards compare against, resolves the suite's
# placement and limits rather than compose's current defaults. Refuses when one is missing.
load_recorded_settings() {
  local spec var path value
  for spec in PYTHON_CPUSET=cores_used_by_suite.python_service_cpuset \
              JAVA_CPUSET=cores_used_by_suite.transaction_service_cpuset \
              K6_CPUSET=cores_used_by_suite.k6_cpuset \
              PYTHON_CPUS=cores_used_by_suite.python_service_cpus_quota \
              JAVA_CPUS=cores_used_by_suite.transaction_service_cpus_quota \
              K6_CPUS=cores_used_by_suite.k6_cpus_quota \
              UVICORN_WORKERS=suite_config.uvicorn_workers \
              THREAD_LIMITER_TOKENS=suite_config.thread_limiter_tokens \
              SUITE_MAX_VUS=suite_config.max_vus \
              SUITE_COOLDOWN_S=suite_config.cooldown_s \
              SUITE_JVM_OPTIONS=jvm_pinned_options; do
    var="${spec%%=*}"
    path="${spec#*=}"
    value=$(suite_metadata "$path")
    if [ -z "$value" ] || [[ "$value" == unknown* ]]; then
      echo "[!] ${RUN_DIR} recorded no ${path}, so the open-loop stack cannot be started on the" \
           "suite run's settings." >&2
      exit 1
    fi
    export "${var}=${value}"
  done
  EXPECTED_THREAD_LIMITER_TOKENS="$THREAD_LIMITER_TOKENS"
  SERVICE_CPUSETS="python=${PYTHON_CPUSET} java=${JAVA_CPUSET} k6=${K6_CPUSET}"
  PINNED_CPUS="${PYTHON_CPUSET},${JAVA_CPUSET},${K6_CPUSET}"
}

# Aborts unless the resolved compose configuration carries the recorded settings and the
# JVM options the suite ran with. JAVA_TOOL_OPTIONS is fixed in docker-compose.yml, so a
# difference there means the file changed after the suite run.
verify_recorded_settings() {
  local spec service key expected resolved
  for spec in "python-service cpuset ${PYTHON_CPUSET}" "transaction-service cpuset ${JAVA_CPUSET}" \
              "k6 cpuset ${K6_CPUSET}" "python-service cpus ${PYTHON_CPUS}" \
              "transaction-service cpus ${JAVA_CPUS}" "k6 cpus ${K6_CPUS}" \
              "python-service UVICORN_WORKERS ${UVICORN_WORKERS}" \
              "python-service THREAD_LIMITER_TOKENS ${THREAD_LIMITER_TOKENS}"; do
    read -r service key expected <<< "$spec"
    resolved=$(compose_service_value "$service" "$key")
    echo "recorded_setting service=${service} key=${key} recorded=${expected} resolved=${resolved:-EMPTY}" >> "$CPU_PIN_LOG"
    # Quotas compare numerically, so "6" and "6.0" are the same limit.
    if [ -z "$resolved" ] || ! awk -v a="$resolved" -v b="$expected" \
        'BEGIN { if (a == b) exit 0; if (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/ && a + 0 == b + 0) exit 0; exit 1 }'; then
      abort_suite "[recorded-settings]" "${service} ${key} resolves to '${resolved:-EMPTY}', but the suite" \
        "run recorded '${expected}' -- the open-loop stack would not run on the suite's configuration."
    fi
  done
  local jvm_now
  jvm_now=$(jvm_pinned_options)
  if [ "$jvm_now" != "$SUITE_JVM_OPTIONS" ]; then
    abort_suite "[recorded-settings]" "JAVA_TOOL_OPTIONS resolves to '${jvm_now:-EMPTY}', but the suite" \
      "run recorded '${SUITE_JVM_OPTIONS}'."
  fi
}

# Moves this target's cells and warm-up files from an earlier invocation, and its lines in
# the failures log, to archive/openloop_<UTC timestamp>/, so reps of two invocations never
# mix in table 7. Other targets' outputs stay.
archive_previous_openloop() {
  local dest f
  local -a old=()
  dest="${RUN_DIR}/archive/openloop_$(run_timestamp)"
  for f in "${RUN_DIR}/openloop_${OPENLOOP_TARGET}_rate"*.json* "${RUN_DIR}/openloop-warmup_${OPENLOOP_TARGET}_"*.json*; do
    if [ -e "$f" ]; then old+=("$f"); fi
  done
  if [ "${#old[@]}" -eq 0 ] && ! grep -q " target=${OPENLOOP_TARGET} " "$FAILURES_LOG" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$dest"
  if [ "${#old[@]}" -gt 0 ]; then mv "${old[@]}" "$dest/"; fi
  if [ -f "$FAILURES_LOG" ]; then
    grep " target=${OPENLOOP_TARGET} " "$FAILURES_LOG" > "${dest}/openloop_failures_log.txt" || true
    grep -v " target=${OPENLOOP_TARGET} " "$FAILURES_LOG" > "${FAILURES_LOG}.tmp" || true
    mv "${FAILURES_LOG}.tmp" "$FAILURES_LOG"
  fi
  echo "[*] Archived the earlier open-loop outputs of target ${OPENLOOP_TARGET} to ${dest}"
}

# Logs the gate's verdict on a finished warm-up file, as table 0 judges the suite's.
log_warmup_verdict() {
  local name="$1" rep="$2" verdict
  verdict=$(python3 "${LIB_DIR}/warmup_gate.py" "${RESULTS_DIR}/${name}.json.gz" --expect "$OPENLOOP_TARGET" \
    --window "$WARMUP_WINDOW" --min-span-s "$WARMUP_WINDOW_MIN_S" --tol "$WARMUP_TAIL_TOLERANCE_PCT" \
    --floor "$WARMUP_TAIL_ABS_FLOOR_MS" 2>/dev/null) || verdict="unreadable"
  echo "openloop_warmup ts=$(thermal_ts) target=${OPENLOOP_TARGET} rep=${rep} file=${name}.json.gz converged=${verdict}" \
    >> "$OPENLOOP_LOG"
}

# One repetition, prepared like a scan rep of the suite: restart, guards, both gated
# warm-up passes and the post-warm-up checks, then every rate once in a fresh order.
openloop_rep() {
  local rep="$1" rate cell
  local -a rates_this_rep
  CURRENT_REP="$rep"
  echo "[*] --- Open-loop repetition ${rep}/${OPENLOOP_REPS} ---"
  record_env_sample "openloop_rep${rep}_start"
  check_power_state "openloop rep=${rep}"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "openloop rep=${rep}"
  verify_jvm_flag_pins "openloop rep=${rep}"
  verify_tiers "openloop rep=${rep}"
  converge_warmup "openloop-warmup_${OPENLOOP_TARGET}_rep${rep}" "${WARMUP_ENV_ARGS[@]}" "REP=${rep}"
  log_warmup_verdict "openloop-warmup_${OPENLOOP_TARGET}_rep${rep}" "$rep"
  verify_tiers_runtime "openloop rep=${rep}"
  verify_jvm_thread_pins "openloop rep=${rep}"
  sleep "$COOLDOWN_S"
  converge_warmup "openloop-warmup_${OPENLOOP_TARGET}_maxvus_rep${rep}" "${WARMUP_MAXVUS_ENV_ARGS[@]}" \
    WARMUP_VUS="$SUITE_MAX_VUS" "REP=${rep}"
  log_warmup_verdict "openloop-warmup_${OPENLOOP_TARGET}_maxvus_rep${rep}" "$rep"
  sleep "$COOLDOWN_S"

  read -ra rates_this_rep <<< "$(shuffled "${RATES[@]}")"
  echo "openloop_order rep=${rep} target=${OPENLOOP_TARGET} rate_order=$(IFS=,; echo "${rates_this_rep[*]}")" >> "$OPENLOOP_LOG"
  echo "  [order] rates this rep: ${rates_this_rep[*]}"
  for rate in "${rates_this_rep[@]}"; do
    cell="openloop_${OPENLOOP_TARGET}_rate${rate}_rep${rep}"
    check_thermal_safety "openloop rate=${rate} rep=${rep} pre-cell"
    echo "  -> ${cell}: ${rate} req/s for ${OPENLOOP_DURATION}"
    run_cell "openloop rate=${rate} rep=${rep}" "$cell" \
      k6_run run-target-openloop.js \
      TARGET="$OPENLOOP_TARGET" RATE="$rate" TIME_UNIT=1s DURATION="$OPENLOOP_DURATION" \
      PRE_ALLOCATED_VUS="$OPENLOOP_PRE_ALLOCATED_VUS" MAX_VUS="$OPENLOOP_MAX_VUS" \
      PHASE="$OPENLOOP_PHASE" REP="$rep" -- \
      --out "json=/results/raw/${cell}.json"
    finalize_result "${cell}.json"
    sleep "$COOLDOWN_S"
  done
  record_env_sample "openloop_rep${rep}_end"
  archive_gc_log "openloop-${OPENLOOP_TARGET}-rep${rep}"
}

load_recorded_settings
COOLDOWN_S="${OPENLOOP_COOLDOWN_S:-$SUITE_COOLDOWN_S}"
if ! [[ "$COOLDOWN_S" =~ ^[0-9]+$ ]]; then
  echo "[!] The cooldown must be a non-negative integer, got '${COOLDOWN_S}'." >&2
  exit 1
fi
# Java's outbound pool to python-service at 2x this check's peak VUs, the rule every
# harness script applies to its own peak, so pool waits never land in the AI call round trip.
export PYTHON_SERVICE_MAX_CONNECTIONS=$((OPENLOOP_MAX_VUS * 2))

archive_previous_openloop
touch "$FAILURES_LOG"
FAILURES_AT_START=$(grep -c . "$FAILURES_LOG" || true)
trap _log_uncaught_exit EXIT
mkdir -p "$RAW_RESULTS_DIR" "${RUN_DIR}/gc-logs"

echo "openloop ts=$(thermal_ts) target=${OPENLOOP_TARGET} plateau_vus_rps=${PLATEAU// /:}" \
     "fractions=${FRACTIONS} rates=$(IFS=,; echo "${RATES[*]}") reps=${OPENLOOP_REPS}" \
     "duration=${OPENLOOP_DURATION} pre_allocated_vus=${OPENLOOP_PRE_ALLOCATED_VUS} max_vus=${OPENLOOP_MAX_VUS}" \
     "phase=${OPENLOOP_PHASE} cooldown_s=${COOLDOWN_S} warmup_maxvus=${SUITE_MAX_VUS}" \
     "java_outbound_max_connections=${PYTHON_SERVICE_MAX_CONNECTIONS} cpusets=${SERVICE_CPUSETS// /,}" \
     "cpus=python:${PYTHON_CPUS},java:${JAVA_CPUS},k6:${K6_CPUS} uvicorn_workers=${UVICORN_WORKERS}" \
     "thread_limiter_tokens=${THREAD_LIMITER_TOKENS} measurement_fingerprint=$(measurement_fingerprint ..)" \
     >> "$OPENLOOP_LOG"
echo "[*] Open-loop: target=${OPENLOOP_TARGET} rates=${RATES[*]} req/s (plateau ${PLATEAU})" \
     "x ${OPENLOOP_REPS} rep(s) -> ${RUN_DIR}"

verify_recorded_settings
verify_smt_isolation "$PYTHON_CPUSET" "$JAVA_CPUSET" "$K6_CPUSET"
verify_service_cpuset "openloop startup" "python-service" "$PYTHON_CPUSET" "$PYTHON_CPUS"
verify_service_cpuset "openloop startup" "transaction-service" "$JAVA_CPUSET" "$JAVA_CPUS"
verify_service_cpuset "openloop startup" "k6" "$K6_CPUSET" "$K6_CPUS"

for rep in $(seq 1 "$OPENLOOP_REPS"); do
  openloop_rep "$rep"
done
CURRENT_REP="none"

docker compose -f "$COMPOSE_FILE" down
rmdir "$RAW_RESULTS_DIR" 2>/dev/null || true
echo "[+] Open-loop cells written to ${RUN_DIR}/openloop_${OPENLOOP_TARGET}_rate*_rep*.json.gz"
echo "    Guard results in ${CPU_PIN_LOG}; aborts, if any, in ${FAILURES_LOG}"
