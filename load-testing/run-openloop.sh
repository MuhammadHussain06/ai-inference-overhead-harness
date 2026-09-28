#!/usr/bin/env bash
# Open-loop validity check against one run-suite.sh run: constant-arrival-rate cells for
# one target, written into that run's directory so analyze-results.py's table 7 compares
# them with the same run's closed-loop scan.
#
# Usage: ./run-openloop.sh [SUITE_RUN_DIR]     (default: this host's latest suite run)
#
# Rates are fractions of the target's closed-loop throughput at the run's highest scan
# concurrency (OPENLOOP_FRACTIONS, default "1.0 0.8"), or explicit via OPENLOOP_RATES.
# Each cell runs on a freshly restarted, warmed-up stack with the suite's thermal guard,
# per-cell thermal and clock samples (openloop_env_trace_log.txt), and the CPU power state
# the suite run recorded, checked at every cell edge.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}." >&2
    exit 1
  fi
done
for _req_lib in lib/host-provenance.sh lib/power-state.sh lib/thermal.sh lib/run-layout.sh lib/k6_filter.py \
  lib/openloop_rates.py lib/warmup_gate.py lib/placement.py lib/cpufreq_sampler.py; do
  if [ ! -r "$_req_lib" ]; then
    echo "[!] Required helper not found: ${_req_lib}." >&2
    exit 1
  fi
done
. lib/host-provenance.sh
. lib/power-state.sh
. lib/thermal.sh
. lib/run-layout.sh

for _sysfs_var in THERMAL_SYSFS_ROOT POWER_SYSFS_ROOT; do
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
OPENLOOP_COOLDOWN_S="${OPENLOOP_COOLDOWN_S:-10}"
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"
# Only the metrics table 7 reads, and the error counters behind its N.
KEEP_METRICS="http_req_duration,http_req_blocked,dropped_iterations,request_http_error,request_timeout_error"
COMPOSE_FILE="../docker-compose.yml"

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

RAW_DIR="${RUN_DIR}/raw"
ENV_TRACE_LOG="${RUN_DIR}/openloop_env_trace_log.txt"
OPENLOOP_LOG="${RUN_DIR}/openloop_log.txt"

compose() {
  RUN_RESULTS_DIR="$RUN_DIR" PYTHON_SERVICE_MAX_CONNECTIONS=$((OPENLOOP_MAX_VUS * 2)) \
    docker compose -f "$COMPOSE_FILE" "$@"
}

# Called by lib/thermal.sh and lib/power-state.sh when the run must stop.
abort_suite() {
  echo "  [FATAL] $1: ${*:2}" >&2
  compose down || true
  exit 1
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
SERVICE_CPUSETS="python=$(suite_metadata cores_used_by_suite.python_service_cpuset)"
SERVICE_CPUSETS+=" java=$(suite_metadata cores_used_by_suite.transaction_service_cpuset)"
SERVICE_CPUSETS+=" k6=$(suite_metadata cores_used_by_suite.k6_cpuset)"
PINNED_CPUS=$(tr ' ' '\n' <<< "$SERVICE_CPUSETS" | cut -d= -f2 | paste -sd, -)

echo "openloop ts=$(thermal_ts) target=${OPENLOOP_TARGET} plateau_vus_rps=${PLATEAU// /:}" \
     "fractions=${FRACTIONS} rates=$(IFS=,; echo "${RATES[*]}")" \
     "duration=${OPENLOOP_DURATION} pre_allocated_vus=${OPENLOOP_PRE_ALLOCATED_VUS} max_vus=${OPENLOOP_MAX_VUS}" \
     "phase=${OPENLOOP_PHASE}" >> "$OPENLOOP_LOG"
echo "[*] Open-loop: target=${OPENLOOP_TARGET} rates=${RATES[*]} req/s (plateau ${PLATEAU}) -> ${RUN_DIR}"

wait_for_ready() {
  local status
  for _ in $(seq 1 60); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/api/v1/transactions \
      -H "Content-Type: application/json" \
      -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
      2>/dev/null) || status="000"
    if [ "$status" = "200" ]; then
      return 0
    fi
    sleep 2
  done
  abort_suite "[ready]" "transaction-service did not respond 200 within 60 attempts."
}

mkdir -p "$RAW_DIR" "${RUN_DIR}/gc-logs"
compose down
compose up -d --wait
wait_for_ready
echo "[*] Warming up target ${OPENLOOP_TARGET} at ${OPENLOOP_PRE_ALLOCATED_VUS} VUs..."
compose --profile loadgen run --rm -T -e WARMUP_TARGETS="$OPENLOOP_TARGET" \
  -e WARMUP_VUS="$OPENLOOP_PRE_ALLOCATED_VUS" k6 run /scripts/warm-up.js < /dev/null
sleep "$OPENLOOP_COOLDOWN_S"

for rate in "${RATES[@]}"; do
  cell="openloop_${OPENLOOP_TARGET}_rate${rate}"
  check_thermal_safety "openloop rate=${rate}"
  check_power_state "openloop rate=${rate}"
  echo "  -> ${cell}: ${rate} req/s for ${OPENLOOP_DURATION}"
  start_freq_sampler "$cell" "$SERVICE_CPUSETS" "$PINNED_CPUS"
  record_cell_thermal start "$cell"
  if ! compose --profile loadgen run --rm -T \
      -e TARGET="$OPENLOOP_TARGET" -e RATE="$rate" -e TIME_UNIT=1s -e DURATION="$OPENLOOP_DURATION" \
      -e PRE_ALLOCATED_VUS="$OPENLOOP_PRE_ALLOCATED_VUS" -e MAX_VUS="$OPENLOOP_MAX_VUS" \
      -e PHASE="$OPENLOOP_PHASE" -e REP=1 \
      k6 run /scripts/run-target-openloop.js --out "json=/results/raw/${cell}.json" < /dev/null; then
    stop_freq_sampler "openloop rate=${rate}"
    abort_suite "[openloop] ${cell}" "k6 exited non-zero."
  fi
  record_cell_thermal end "$cell"
  stop_freq_sampler "openloop rate=${rate}"
  check_power_state "openloop rate=${rate}"
  python3 "${LIB_DIR}/k6_filter.py" finalize "${RAW_DIR}/${cell}.json" "${RUN_DIR}/${cell}.json.gz" "$KEEP_METRICS"
  rm -f "${RAW_DIR}/${cell}.json"
  sleep "$OPENLOOP_COOLDOWN_S"
done

compose down
if [ -f "${RUN_DIR}/gc-logs/gc.log" ]; then
  mv "${RUN_DIR}/gc-logs/gc.log" "${RUN_DIR}/gc-logs/gc_openloop_$(run_timestamp).log"
fi
rmdir "$RAW_DIR" 2>/dev/null || true
echo "[+] Open-loop cells written to ${RUN_DIR}/openloop_${OPENLOOP_TARGET}_rate*.json.gz"
