#!/usr/bin/env bash
set -euo pipefail

# Standalone diagnostic, not called by run-suite.sh or run-ablation.sh.
# converge_warmup() passes only when every expected target (all six by default) converges
# in the same chunk. This warms all six targets per chunk, past the MAX_WARMUP_CHUNKS cap,
# and prints each target's verdict and the joint result at every checkpoint, to show
# whether the joint condition is reachable and which target lags.
# probe_warmup_settle.sh covers a single target.
#
# Usage:
#   ./probe_warmup_joint.sh LABEL VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S] [WINDOW] [TOL] [ABS_FLOOR_MS] [MIN_SPAN_S]
#
# VUS=5 reproduces the baseline and default-VUS scan warm-up; VUS=64 (MAX_VUS) the
# max-VUS pass. CPUSET/CPUS/WORKERS/TOKENS default to docker-compose.yml's defaults.
# WINDOW/TOL/ABS_FLOOR_MS/MIN_SPAN_S default to converge_warmup()'s values, and every
# checkpoint runs lib/warmup_gate.py itself, so the verdicts are the real gate's.
#
# Examples:
#   ./probe_warmup_joint.sh joint_baseline 5
#   ./probe_warmup_joint.sh joint_maxvus 64

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="$(cd ../lib && pwd)"

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

LABEL="${1:?usage: probe_warmup_joint.sh LABEL VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S] [WINDOW] [TOL] [ABS_FLOOR_MS] [MIN_SPAN_S]}"
VUS="${2:?vus required}"
CPUSET="${3:-0-1,4-5,8-9}"
CPUS="${4:-6.0}"
WORKERS="${5:-3}"
TOKENS="${6:-40}"
MAX_CHUNKS="${7:-20}"
CHUNK_DURATION_S="${8:-15}"
WINDOW="${9:-500}"
TOL="${10:-5.0}"
ABS_FLOOR_MS="${11:-0.25}"
MIN_SPAN_S="${12:-3}"

# Matches run-suite.sh's TARGETS default and warm-up.js's own default ORDER.
TARGETS="mock calibration 5 10 20 28"

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

# Runs the gate as converge_warmup() does: per-target verdicts, plus the joint result
# converge_warmup() acts on but does not print.
report_checkpoint() {
  local combined="$1" chunk="$2" joint
  joint=$(python3 "${LIB_DIR}/warmup_gate.py" "$combined" --expect "$TARGETS" --label "checkpoint ${chunk}" \
    --window "$WINDOW" --min-span-s "$MIN_SPAN_S" --tol "$TOL" --floor "$ABS_FLOOR_MS")
  if [ "$joint" = "true" ]; then
    echo "  [checkpoint ${chunk}] [joint] ALL TARGETS CONVERGED"
  else
    echo "  [checkpoint ${chunk}] [joint] NOT ALL CONVERGED -- see the per-target lines above"
  fi
}

restart_stack
wait_for_ready

combined="${RAW_RESULTS_DIR}/${LABEL}_combined.json"
: > "$combined"

echo "[*] ${LABEL}: targets=(${TARGETS}) vus=${VUS} cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} tokens=${TOKENS} window=${WINDOW} min_span_s=${MIN_SPAN_S} tol=${TOL} abs_floor_ms=${ABS_FLOOR_MS}"
echo "[*] running up to ${MAX_CHUNKS} chunks of ${CHUNK_DURATION_S}s/target, 6 targets/chunk as 6 separate calls" \
     "(~$((MAX_CHUNKS * CHUNK_DURATION_S * 6))s of load plus per-call container overhead) -- not stopping early, we want the full curve"

# One warm-up.js call per target rather than one six-target call (as converge_warmup()
# does), so check_thermal_safety runs between targets, not only between chunks.
for chunk in $(seq 1 "$MAX_CHUNKS"); do
  for tier in $TARGETS; do
    target_name="${LABEL}_chunk${chunk}_${tier}.json"
    k6_run warm-up.js WARMUP_TARGETS="$tier" WARMUP_VUS="$VUS" WARMUP_DURATION_S="$CHUNK_DURATION_S" -- \
      --out "json=/results/probes/raw/${target_name}"
    # Only the metric the gate reads: the combined file grows for the whole probe,
    # uncompressed, and k6 writes a line per metric per request.
    python3 "${LIB_DIR}/k6_filter.py" append "${RAW_RESULTS_DIR}/${target_name}" "$combined" http_req_duration
    rm -f "${RAW_RESULTS_DIR}/${target_name}"
    check_thermal_safety "${LABEL} chunk${chunk} tier=${tier}"
  done
  report_checkpoint "$combined" "$chunk"
done

python3 "${LIB_DIR}/k6_filter.py" gzip "$combined" "${RESULTS_DIR}/${LABEL}.json.gz"
rm -f "$combined"

docker compose -f "$COMPOSE_FILE" down

echo "[+] ${LABEL} done. Full checkpoint history is above; raw data saved to ${RESULTS_DIR}/${LABEL}.json.gz"