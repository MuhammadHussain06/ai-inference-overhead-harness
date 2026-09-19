#!/usr/bin/env bash
set -euo pipefail

# Standalone diagnostic -- not wired into run-suite.sh or run-ablation.sh.
# run-suite.sh's converge_warmup() gates the baseline and scan warm-up passes
# on ALL SIX targets (WARMUP_TARGETS="mock calibration 5 10 20 28") converging
# in the SAME chunk, not on any one target in isolation. probe_warmup_settle.sh
# only probes one target at a time, so it can't show whether that harder,
# joint AND condition is actually reachable, or which target is the laggard
# when it isn't. This runs the same all-six-targets-per-chunk warm-up.js call
# converge_warmup() makes, past its MAX_WARMUP_CHUNKS cap, printing every
# target's tail drift and the joint pass/fail at each checkpoint.
#
# Usage:
#   ./probe_warmup_joint.sh LABEL VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S] [WINDOW] [TOL] [ABS_FLOOR_MS]
#
# VUS=5 reproduces the baseline/default-VUS-scan warm-up call; VUS=64 (this
# suite's MAX_VUS) reproduces the scan_maxvus call. CPUSET/CPUS/WORKERS/TOKENS
# default to docker-compose.yml's own defaults, matching both real call sites.
# WINDOW/TOL/ABS_FLOOR_MS default to converge_warmup()'s own production
# values, so this reproduces the real gate unless overridden.
#
# Examples:
#   ./probe_warmup_joint.sh joint_baseline 5
#   ./probe_warmup_joint.sh joint_maxvus 64

cd "$(dirname "${BASH_SOURCE[0]}")"

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

LABEL="${1:?usage: probe_warmup_joint.sh LABEL VUS [CPUSET CPUS WORKERS TOKENS] [MAX_CHUNKS] [CHUNK_DURATION_S] [WINDOW] [TOL] [ABS_FLOOR_MS]}"
VUS="${2:?vus required}"
CPUSET="${3:-0-1,4-5,8-9}"
CPUS="${4:-6.0}"
WORKERS="${5:-3}"
TOKENS="${6:-40}"
MAX_CHUNKS="${7:-20}"
CHUNK_DURATION_S="${8:-15}"
WINDOW="${9:-100}"
TOL="${10:-5.0}"
ABS_FLOOR_MS="${11:-0.25}"

# Matches run-suite.sh's TARGETS default and warm-up.js's own default ORDER.
TARGETS="mock calibration 5 10 20 28"

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

# Prints every target's tail drift and whether ALL of them converge in this
# SAME chunk -- reproduces converge_warmup()'s by-tier AND check in run-suite.sh
# exactly (same window/median/drift math), plus which target(s) are still
# moving when the joint check fails, which converge_warmup() itself doesn't
# report.
report_checkpoint() {
  local combined="$1" chunk="$2"
  python3 - "$combined" "$WINDOW" "$TOL" "$ABS_FLOOR_MS" "$chunk" "$TARGETS" <<'PYEOF'
import json, sys
from collections import defaultdict

fp, window, tol, abs_floor, chunk, targets = (
    sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5], sys.argv[6].split()
)

by_tier = defaultdict(list)
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
        if tags.get("status") != "200":
            continue
        tier, t, v = tags.get("tier"), data.get("time"), data.get("value")
        if tier is not None and t is not None and v is not None:
            by_tier[tier].append((t, v))

all_converged = True
blocking = []
for tier in targets:
    pts = by_tier.get(tier, [])
    n = len(pts)
    if n < 3 * window:
        print(f"  [checkpoint {chunk}] tier={tier} n={n} -- not enough data yet for a {window}-window read")
        all_converged = False
        blocking.append(tier)
        continue
    pts.sort(key=lambda p: p[0])
    prev = sorted(v for _, v in pts[-2 * window:-window])[window // 2]
    last = sorted(v for _, v in pts[-window:])[window // 2]
    drift = 100 * (last - prev) / prev if prev else float("inf")
    converged = abs(last - prev) < abs_floor or abs(drift) < tol
    tag = "CONVERGED" if converged else "still moving"
    print(f"  [checkpoint {chunk}] tier={tier} n={n} prev{window}={prev:.3f}ms last{window}={last:.3f}ms "
          f"drift={drift:+.1f}% (abs_diff={abs(last - prev):.3f}ms) ({tag})")
    if not converged:
        all_converged = False
        blocking.append(tier)

if all_converged:
    print(f"  [checkpoint {chunk}] [joint] ALL SIX CONVERGED")
else:
    print(f"  [checkpoint {chunk}] [joint] NOT ALL CONVERGED -- blocking: {','.join(blocking)}")
PYEOF
}

restart_stack
wait_for_ready

combined="${RAW_RESULTS_DIR}/${LABEL}_combined.json"
: > "$combined"

echo "[*] ${LABEL}: targets=(${TARGETS}) vus=${VUS} cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} tokens=${TOKENS} window=${WINDOW} tol=${TOL} abs_floor_ms=${ABS_FLOOR_MS}"
echo "[*] running up to ${MAX_CHUNKS} chunks of ${CHUNK_DURATION_S}s/target, 6 targets/chunk as 6 separate calls" \
     "(~$((MAX_CHUNKS * CHUNK_DURATION_S * 6))s of load plus per-call container overhead) -- not stopping early, we want the full curve"

# Each target in a chunk runs as its own warm-up.js call instead of one call
# covering all six -- a single six-target call keeps the pinned cores under
# continuous load for ~2.5 minutes before check_thermal_safety ever gets to
# look, versus ~15-25s per target here, so a hot system gets caught between
# targets instead of only between chunks.
for chunk in $(seq 1 "$MAX_CHUNKS"); do
  for tier in $TARGETS; do
    target_name="${LABEL}_chunk${chunk}_${tier}.json"
    k6_run warm-up.js WARMUP_TARGETS="$tier" WARMUP_VUS="$VUS" WARMUP_DURATION_S="$CHUNK_DURATION_S" -- \
      --out "json=/results/probes/raw/${target_name}"
    filter_and_append "${RAW_RESULTS_DIR}/${target_name}" "$combined"
    rm -f "${RAW_RESULTS_DIR}/${target_name}"
    check_thermal_safety "${LABEL} chunk${chunk} tier=${tier}"
  done
  report_checkpoint "$combined" "$chunk"
done

gzip -c "$combined" > "${RESULTS_DIR}/${LABEL}.json.gz"
rm -f "$combined"

docker compose -f "$COMPOSE_FILE" down

echo "[+] ${LABEL} done. Full checkpoint history is above; raw data saved to ${RESULTS_DIR}/${LABEL}.json.gz"