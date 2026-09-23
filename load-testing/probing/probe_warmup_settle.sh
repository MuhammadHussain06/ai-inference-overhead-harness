#!/usr/bin/env bash
set -euo pipefail

# Standalone diagnostic -- not wired into run-suite.sh or run-ablation.sh.
# converge_warmup() in both scripts stops at MAX_WARMUP_CHUNKS and reports
# whether a target converged by then, without showing where a non-converging
# target actually settles. Runs the same duration-bounded, constant-vus
# warm-up.js chunks converge_warmup() uses, past that cap, printing the gate's
# own verdict (lib/warmup_gate.py) at every checkpoint.
#
# Usage:
#   ./probe_warmup_settle.sh LABEL TIER VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S]
#
# TIER is a single warm-up.js target key (mock|calibration|5|10|20|28).
# CPUSET/CPUS/WORKERS/TOKENS default to docker-compose.yml's own defaults
# (the main-suite condition); pass all four to reproduce an ablation arm.
# WARMUP_WINDOW_OVERRIDE / WARMUP_MIN_SPAN_OVERRIDE / WARMUP_TOL_OVERRIDE /
# WARMUP_ABS_FLOOR_OVERRIDE change the criterion from the gate's defaults
# (500 requests, 3 s, 5%, 0.25 ms), to check how a target's verdict depends on
# the window and bounds at its own per-request variance.
#
# Examples:
#   ./probe_warmup_settle.sh v20_baseline 20 5
#   ./probe_warmup_settle.sh v28_maxvus 28 64
#   ./probe_warmup_settle.sh ablation_cpu01 28 64 0-1 2.0 3 40
#   ./probe_warmup_settle.sh ablation_tokens64 28 64 0-1,4-5,8-9 6.0 3 64
#   WARMUP_MIN_SPAN_OVERRIDE=0 ./probe_warmup_settle.sh mock_count_window mock 64

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="$(cd ../lib && pwd)"

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

LABEL="${1:?usage: probe_warmup_settle.sh LABEL TIER VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S]}"
TIER="${2:?tier required}"
VUS="${3:?vus required}"
CPUSET="${4:-0-1,4-5,8-9}"
CPUS="${5:-6.0}"
WORKERS="${6:-3}"
TOKENS="${7:-40}"
MAX_CHUNKS="${8:-20}"
CHUNK_DURATION_S="${9:-15}"

WINDOW="${WARMUP_WINDOW_OVERRIDE:-500}"
MIN_SPAN_S="${WARMUP_MIN_SPAN_OVERRIDE:-3}"
TOL="${WARMUP_TOL_OVERRIDE:-5.0}"
ABS_FLOOR_MS="${WARMUP_ABS_FLOOR_OVERRIDE:-0.25}"

COMPOSE_FILE="../../docker-compose.yml"
RESULTS_DIR="../../results/probes"
RAW_RESULTS_DIR="${RESULTS_DIR}/raw"
mkdir -p "$RESULTS_DIR" "$RAW_RESULTS_DIR"
ENV_TRACE_LOG="${RESULTS_DIR}/${LABEL}_thermal_log.txt"
: > "$ENV_TRACE_LOG"

# shellcheck disable=SC2034  # read by lib/thermal.sh
{
  THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
  THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
  THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
  MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
}

abort_suite() {
  local label="$1"; shift
  echo "  [FATAL] ${label}: $*" >&2
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

# shellcheck source=../lib/thermal.sh
. "${LIB_DIR}/thermal.sh"

restart_stack() {
  echo "  [restart] cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} thread_limiter_tokens=${TOKENS}"
  docker compose -f "$COMPOSE_FILE" down
  PYTHON_CPUSET="$CPUSET" PYTHON_CPUS="$CPUS" UVICORN_WORKERS="$WORKERS" THREAD_LIMITER_TOKENS="$TOKENS" \
    docker compose -f "$COMPOSE_FILE" up -d --wait
}

wait_for_ready() {
  local url="http://localhost:8080/api/v1/transactions"
  local status="000"
  for i in $(seq 1 60); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
      2>/dev/null) || status="000"
    [ "$status" = "200" ] && { echo "  [ready] after ${i} attempt(s)."; return 0; }
    sleep 2
  done
  abort_suite "[ready]" "transaction-service did not respond 200 within 60 attempts (last status ${status})."
}

k6_run() {
  local script="$1"; shift
  local env_flags=()
  while [ "$1" != "--" ]; do env_flags+=("-e" "$1"); shift; done
  shift
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    "${env_flags[@]}" k6 run "/scripts/${script}" "$@"
}

restart_stack
wait_for_ready

combined="${RAW_RESULTS_DIR}/${LABEL}_combined.json"
: > "$combined"

echo "[*] ${LABEL}: tier=${TIER} vus=${VUS} cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} tokens=${TOKENS}"
echo "[*] criterion: window>=${WINDOW} requests spanning >=${MIN_SPAN_S}s, tail <${TOL}% or <${ABS_FLOOR_MS}ms"
echo "[*] running up to ${MAX_CHUNKS} chunks of ${CHUNK_DURATION_S}s/target (~$((MAX_CHUNKS * CHUNK_DURATION_S))s total) -- not stopping early, we want the full curve"

for chunk in $(seq 1 "$MAX_CHUNKS"); do
  chunk_name="${LABEL}_chunk${chunk}.json"
  k6_run warm-up.js WARMUP_TARGETS="$TIER" WARMUP_VUS="$VUS" WARMUP_DURATION_S="$CHUNK_DURATION_S" -- \
    --out "json=/results/probes/raw/${chunk_name}"
  # Only the metric the gate reads: the combined file grows for the whole probe,
  # uncompressed, and k6 writes a line per metric per request.
  python3 "${LIB_DIR}/k6_filter.py" append "${RAW_RESULTS_DIR}/${chunk_name}" "$combined" http_req_duration
  rm -f "${RAW_RESULTS_DIR}/${chunk_name}"
  check_thermal_safety "${LABEL} chunk${chunk}"
  python3 "${LIB_DIR}/warmup_gate.py" "$combined" --expect "$TIER" --label "checkpoint ${chunk}" \
    --window "$WINDOW" --min-span-s "$MIN_SPAN_S" --tol "$TOL" --floor "$ABS_FLOOR_MS" > /dev/null
done

python3 "${LIB_DIR}/k6_filter.py" gzip "$combined" "${RESULTS_DIR}/${LABEL}.json.gz"
rm -f "$combined"

docker compose -f "$COMPOSE_FILE" down

echo "[+] ${LABEL} done. Full checkpoint history is above; raw data saved to ${RESULTS_DIR}/${LABEL}.json.gz"
