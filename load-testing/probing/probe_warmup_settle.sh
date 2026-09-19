#!/usr/bin/env bash
set -euo pipefail

# Standalone diagnostic -- not wired into run-suite.sh or run-ablation.sh.
# converge_warmup() in both scripts stops at MAX_WARMUP_CHUNKS and reports
# whether a target converged by then, without showing where a non-converging
# target actually settles. Runs the same duration-bounded, constant-vus
# warm-up.js chunks converge_warmup() uses, past that cap, printing the
# tail-drift at every checkpoint.
#
# Usage:
#   ./probe_warmup_settle.sh LABEL TIER VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S]
#
# TIER is a single warm-up.js target key (mock|calibration|5|10|20|28).
# CPUSET/CPUS/WORKERS/TOKENS default to docker-compose.yml's own defaults
# (the main-suite condition); pass all four to reproduce an ablation arm.
# WARMUP_WINDOW_OVERRIDE / WARMUP_TOL_OVERRIDE / WARMUP_ABS_FLOOR_OVERRIDE
# widen the checkpoint window, tolerance, or absolute floor beyond table0's
# WARMUP_WINDOW=100 / WARMUP_TAIL_TOLERANCE_PCT=5.0 /
# WARMUP_TAIL_ABS_FLOOR_MS=0.25, to check whether the production window is
# noise-dominated at a target's steady-state per-request variance.
#
# Examples:
#   ./probe_warmup_settle.sh v20_baseline 20 5
#   ./probe_warmup_settle.sh v28_maxvus 28 64
#   ./probe_warmup_settle.sh ablation_cpu01 28 64 0-1 2.0 3 40
#   ./probe_warmup_settle.sh ablation_tokens64 28 64 0-1,4-5,8-9 6.0 3 64
#   WARMUP_WINDOW_OVERRIDE=400 ./probe_warmup_settle.sh v20_wide400 20 5

cd "$(dirname "${BASH_SOURCE[0]}")"

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

WINDOW="${WARMUP_WINDOW_OVERRIDE:-100}"
TOL="${WARMUP_TOL_OVERRIDE:-5.0}"
ABS_FLOOR_MS="${WARMUP_ABS_FLOOR_OVERRIDE:-0.25}"

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results/probes"
RAW_RESULTS_DIR="${RESULTS_DIR}/raw"
mkdir -p "$RESULTS_DIR" "$RAW_RESULTS_DIR"

THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"

abort_probe() {
  echo "  [FATAL] $*" >&2
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

# Highest reading across all thermal zones, whole degrees C. Empty output
# means no zone was readable -- callers treat that as "skip the check", not
# as an abort, since this is a safety net on top of the real run, not a
# requirement for it.
read_max_cpu_temp_c() {
  local max="" raw t zone
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    raw=$(cat "$zone" 2>/dev/null) || continue
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    t=$((raw / 1000))
    if [ -z "$max" ] || [ "$t" -gt "$max" ]; then
      max="$t"
    fi
  done
  echo "$max"
  return 0
}

# Pauses if temps are at/above THERMAL_WARN_C, giving the system a chance to
# cool; aborts if still at/above THERMAL_CRIT_C after MAX_THERMAL_COOLDOWNS
# pauses. Errs toward pausing over aborting on the first warning -- a hard
# hang loses the whole run, a paused one only costs wall-clock time.
check_thermal_safety() {
  local label="$1"
  local temp cooldowns=0
  temp=$(read_max_cpu_temp_c)
  [ -z "$temp" ] && return 0
  while [ "$temp" -ge "$THERMAL_WARN_C" ] && [ "$cooldowns" -lt "$MAX_THERMAL_COOLDOWNS" ]; do
    echo "  [thermal] ${label}: ${temp}C >= warn ${THERMAL_WARN_C}C -- cooling ${THERMAL_COOLDOWN_S}s ($((cooldowns + 1))/${MAX_THERMAL_COOLDOWNS})"
    sleep "$THERMAL_COOLDOWN_S"
    cooldowns=$((cooldowns + 1))
    temp=$(read_max_cpu_temp_c)
    [ -z "$temp" ] && return 0
  done
  if [ "$temp" -ge "$THERMAL_CRIT_C" ]; then
    abort_probe "[thermal] ${label}: ${temp}C still >= critical ${THERMAL_CRIT_C}C after ${cooldowns} cooldown(s)."
  fi
}

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
  abort_probe "[ready] transaction-service did not respond 200 within 60 attempts (last status ${status})."
}

k6_run() {
  local script="$1"; shift
  local env_flags=()
  while [ "$1" != "--" ]; do env_flags+=("-e" "$1"); shift; done
  shift
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    "${env_flags[@]}" k6 run "/scripts/${script}" "$@"
}

# k6's raw --out json dump writes a line per metric per request -- roughly
# 15-20 lines for every one that report_checkpoint actually reads
# (http_req_duration). combined accumulates for the whole probe, uncompressed,
# across every chunk, so appending the unfiltered dump can exhaust disk well
# before a long run finishes. Keeps only the metric report_checkpoint reads,
# same idea as finalize_result()'s KEEP_METRICS filtering in run-suite.sh.
filter_and_append() {
  local raw="$1" dest="$2"
  python3 -c "
import json, sys
with open(sys.argv[1]) as fin, open(sys.argv[2], 'a') as fout:
    for line in fin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get('type') == 'Point' and obj.get('metric') == 'http_req_duration':
            fout.write(line + '\n')
" "$raw" "$dest"
}

# Prints cumulative N, first/prev/last-window P50 and tail drift for TIER at
# this checkpoint -- same window/percentile convention as table0, just run at
# every chunk instead of once at a fixed cap.
report_checkpoint() {
  local combined="$1" chunk="$2"
  python3 - "$combined" "$WINDOW" "$TOL" "$ABS_FLOOR_MS" "$TIER" "$chunk" <<'PYEOF'
import json, sys

fp, window, tol, abs_floor, tier, chunk = (
    sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5], sys.argv[6]
)
pts = []
with open(fp) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") != "Point" or obj.get("metric") != "http_req_duration":
            continue
        data = obj.get("data", {}) or {}
        tags = data.get("tags", {}) or {}
        if tags.get("tier") != tier or tags.get("status") != "200":
            continue
        t, v = data.get("time"), data.get("value")
        if t is not None and v is not None:
            pts.append((t, v))

n = len(pts)
if n < 3 * window:
    print(f"  [checkpoint {chunk}] n={n} -- not enough data yet for a {window}-window read")
    sys.exit()

pts.sort(key=lambda p: p[0])
first = sorted(v for _, v in pts[:window])[window // 2]
prev = sorted(v for _, v in pts[-2 * window:-window])[window // 2]
last = sorted(v for _, v in pts[-window:])[window // 2]
drift = 100 * (last - prev) / prev if prev else float("inf")
total_drift = 100 * (last - first) / first if first else float("inf")
tag = "CONVERGED" if abs(last - prev) < abs_floor or abs(drift) < tol else "still moving"
print(f"  [checkpoint {chunk}] n={n} first{window}={first:.3f}ms prev{window}={prev:.3f}ms "
      f"last{window}={last:.3f}ms tail_drift={drift:+.1f}% (abs_diff={abs(last - prev):.3f}ms) "
      f"total_drift={total_drift:+.1f}% ({tag})")
PYEOF
}

restart_stack
wait_for_ready

combined="${RAW_RESULTS_DIR}/${LABEL}_combined.json"
: > "$combined"

echo "[*] ${LABEL}: tier=${TIER} vus=${VUS} cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} tokens=${TOKENS}"
echo "[*] running up to ${MAX_CHUNKS} chunks of ${CHUNK_DURATION_S}s/target (~$((MAX_CHUNKS * CHUNK_DURATION_S))s total) -- not stopping early, we want the full curve"

for chunk in $(seq 1 "$MAX_CHUNKS"); do
  chunk_name="${LABEL}_chunk${chunk}.json"
  k6_run warm-up.js WARMUP_TARGETS="$TIER" WARMUP_VUS="$VUS" WARMUP_DURATION_S="$CHUNK_DURATION_S" -- \
    --out "json=/results/probes/raw/${chunk_name}"
  filter_and_append "${RAW_RESULTS_DIR}/${chunk_name}" "$combined"
  rm -f "${RAW_RESULTS_DIR}/${chunk_name}"
  check_thermal_safety "${LABEL} chunk${chunk}"
  report_checkpoint "$combined" "$chunk"
done

gzip -c "$combined" > "${RESULTS_DIR}/${LABEL}.json.gz"
rm -f "$combined"

docker compose -f "$COMPOSE_FILE" down

echo "[+] ${LABEL} done. Full checkpoint history is above; raw data saved to ${RESULTS_DIR}/${LABEL}.json.gz"