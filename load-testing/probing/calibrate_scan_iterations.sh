#!/usr/bin/env bash
# Standalone probe -- NOT wired into run-suite.sh. Run by hand to check the
# calibration idea against a given tier before it goes anywhere near the
# real pipeline.
#
# What it does: runs one short cell at a reference VUS to measure that
# tier's real throughput, then prints the ITERATIONS_PER_VU needed at each
# affected concurrency level (8/16/32/64) to reach a target cell duration
# (default 60s). Relies on the finding validated tonight at 4 tier/VUS
# combinations: a given tier's total throughput stays roughly constant
# across VUS, so one measurement is enough to derive all four levels.
#
# Usage: ./calibrate_scan_iterations.sh TIER [REFERENCE_VUS] [TARGET_DURATION_S] [CALIBRATION_ITER_PER_VU]
set -euo pipefail

TIER="${1:?usage: calibrate_scan_iterations.sh TIER [REFERENCE_VUS] [TARGET_DURATION_S] [CALIBRATION_ITER_PER_VU]}"
REFERENCE_VUS="${2:-16}"
TARGET_DURATION_S="${3:-60}"
CALIBRATION_ITER_PER_VU="${4:-2000}"

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="${RESULTS_DIR_OVERRIDE:-../results}"
# Path as the k6 container sees it (docker-compose.yml mounts ./results -> /results).
CONTAINER_OUT="/results/calib_${TIER}_vus${REFERENCE_VUS}.json"
# Same file, as this host sees it -- the python step below runs outside docker.
HOST_OUT="${RESULTS_DIR}/calib_${TIER}_vus${REFERENCE_VUS}.json"

echo "[calibrate] measuring throughput for tier=${TIER} at VUS=${REFERENCE_VUS} (${CALIBRATION_ITER_PER_VU} iter/vu)..."
docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
  -e TARGET="$TIER" -e VUS="$REFERENCE_VUS" -e ITERATIONS_PER_VU="$CALIBRATION_ITER_PER_VU" \
  -e PHASE=scan -e REP=calib \
  k6 run /scripts/run-target.js --out "json=${CONTAINER_OUT}"

python3 - "$HOST_OUT" "$REFERENCE_VUS" "$TARGET_DURATION_S" <<'PYEOF'
import json, re, sys
from datetime import datetime

def parse_iso(ts):
    # k6 emits RFC3339 with a trailing Z and sometimes nanosecond precision;
    # datetime.fromisoformat wants +00:00 and at most 6 fractional digits.
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts)
    return datetime.fromisoformat(ts)

fp, ref_vus, target_s = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
times = []
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
        tags = obj["data"].get("tags", {}) or {}
        if tags.get("phase") != "scan":
            continue
        times.append(parse_iso(obj["data"]["time"]))

n = len(times)
duration = (max(times) - min(times)).total_seconds()
throughput = n / duration
target_total_requests = throughput * target_s

print(f"measured: n={n} duration={duration:.2f}s throughput={throughput:.1f} req/s")
print(f"target total requests for {target_s:.0f}s: {target_total_requests:.0f}")
print()
print("suggested ITERATIONS_PER_VU by concurrency level:")
for vus in (8, 16, 32, 64):
    iters = max(1, round(target_total_requests / vus))
    print(f"  VUS={vus:3d}  ITERATIONS_PER_VU={iters}")
PYEOF