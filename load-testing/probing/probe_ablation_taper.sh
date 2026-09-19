#!/usr/bin/env bash
# Standalone probe -- NOT wired into run-ablation.sh. Checks whether ablation
# cells, fixed at TARGET=28 VUS=64 ITERATIONS_PER_VU=100 (the exact
# combination independently measured at -75% raw / -47% trimmed drift in the
# main scan), show the same per-vu-iterations wind-down contamination here,
# and whether extending cell duration fixes it under this arm's real
# processing capacity. Each ablation arm genuinely changes python-service's
# throughput by design, so this has to be checked per config, not assumed
# from the main scan's tier=28 numbers alone.
#
# Usage: ./probe_ablation_taper.sh LABEL CPUSET CPUS WORKERS TOKENS [TARGET_DURATION_S]
set -euo pipefail

LABEL="${1:?usage: probe_ablation_taper.sh LABEL CPUSET CPUS WORKERS TOKENS [TARGET_DURATION_S]}"
CPUSET="${2:?cpuset required}"
CPUS="${3:?cpus required}"
WORKERS="${4:?workers required}"
TOKENS="${5:?tokens required}"
TARGET_DURATION_S="${6:-60}"

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
TARGET=28
VUS=64
SHORT_ITER_PER_VU=100   # matches the real ablation cell exactly
CALIB_ITER_PER_VU=500   # small, quick throughput measurement

echo "[probe] ${LABEL}: restarting stack (cpuset=${CPUSET} cpus=${CPUS} workers=${WORKERS} tokens=${TOKENS})..."
docker compose -f "$COMPOSE_FILE" down
PYTHON_CPUSET="$CPUSET" PYTHON_CPUS="$CPUS" UVICORN_WORKERS="$WORKERS" THREAD_LIMITER_TOKENS="$TOKENS" \
  docker compose -f "$COMPOSE_FILE" up -d --wait

echo "[probe] ${LABEL}: waiting for transaction-service..."
url="http://localhost:8080/api/v1/transactions"
ready=0
for i in $(seq 1 60); do
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
    2>/dev/null) || status="000"
  if [ "$status" = "200" ]; then echo "[probe] ready after ${i} attempt(s)."; ready=1; break; fi
  sleep 2
done
[ "$ready" = "1" ] || { echo "[probe] never became ready (last status ${status:-none})"; exit 1; }

echo "[probe] ${LABEL}: short cell, matches the real ablation cell (ITERATIONS_PER_VU=${SHORT_ITER_PER_VU})..."
docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
  -e TARGET="$TARGET" -e VUS="$VUS" -e ITERATIONS_PER_VU="$SHORT_ITER_PER_VU" -e PHASE=ablation -e REP=probe_short \
  -e ARM=probe -e ARM_VALUE="$LABEL" \
  k6 run /scripts/run-target.js --out "json=/results/probe_ablation_${LABEL}_short.json"

sleep 10

echo "[probe] ${LABEL}: calibration cell (ITERATIONS_PER_VU=${CALIB_ITER_PER_VU}) to measure real throughput..."
docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
  -e TARGET="$TARGET" -e VUS="$VUS" -e ITERATIONS_PER_VU="$CALIB_ITER_PER_VU" -e PHASE=ablation -e REP=probe_calib \
  -e ARM=probe -e ARM_VALUE="$LABEL" \
  k6 run /scripts/run-target.js --out "json=/results/probe_ablation_${LABEL}_calib.json"

long_iter_per_vu=$(python3 - "${RESULTS_DIR}/probe_ablation_${LABEL}_calib.json" "$VUS" "$TARGET_DURATION_S" <<'PYEOF'
import json, re, sys
from datetime import datetime

def parse_iso(ts):
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts)
    return datetime.fromisoformat(ts)

fp, vus, target_s = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
times = []
with open(fp) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("type") != "Point" or obj.get("metric") != "http_req_duration":
            continue
        if (obj["data"].get("tags") or {}).get("phase") != "ablation":
            continue
        times.append(parse_iso(obj["data"]["time"]))
times.sort()
duration = (times[-1] - times[0]).total_seconds()
throughput = len(times) / duration
target_total_requests = throughput * target_s
print(max(1, round(target_total_requests / vus)))
PYEOF
)
echo "[probe] ${LABEL}: measured throughput implies ITERATIONS_PER_VU=${long_iter_per_vu} for a ${TARGET_DURATION_S}s cell"

sleep 10

echo "[probe] ${LABEL}: long cell (ITERATIONS_PER_VU=${long_iter_per_vu})..."
docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
  -e TARGET="$TARGET" -e VUS="$VUS" -e ITERATIONS_PER_VU="$long_iter_per_vu" -e PHASE=ablation -e REP=probe_long \
  -e ARM=probe -e ARM_VALUE="$LABEL" \
  k6 run /scripts/run-target.js --out "json=/results/probe_ablation_${LABEL}_long.json"

echo "[probe] ${LABEL}: done."
echo "  upload probe_ablation_${LABEL}_short.json and probe_ablation_${LABEL}_long.json"