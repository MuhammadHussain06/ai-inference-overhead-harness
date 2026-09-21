#!/usr/bin/env bash
# Standalone probe -- NOT wired into run-suite.sh. Run by hand, stack already up.
#
# calibrate_target() in run-suite.sh remeasures a target's throughput once per
# rep (REPS_SCAN times), even though the quantity it measures -- a target's
# throughput at a reference VUS -- is assumed constant across reps. If that
# holds, most of those remeasurements are redundant wall-clock cost that could
# be cut by calibrating once per target instead of once per (target, rep),
# without touching REPS_SCAN itself. This probe checks whether it holds on
# this host: it repeats calibrate_target's own measurement back-to-back and
# reports how much the result actually moves.
#
# Usage: ./probe_calibration_drift.sh TIER [N_MEASUREMENTS] [REFERENCE_VUS] [ITER_PER_VU] [COOLDOWN_S]
# Defaults mirror run-suite.sh's own calibration: REFERENCE_VUS=16 (CALIB_VUS),
# ITER_PER_VU=2000 (CALIB_ITER_PER_VU), COOLDOWN_S=10 (COOLDOWN_S),
# N_MEASUREMENTS=7 (REPS_SCAN) so the spread reflects what a real run would see.
set -euo pipefail

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

TIER="${1:?usage: probe_calibration_drift.sh TIER [N_MEASUREMENTS] [REFERENCE_VUS] [ITER_PER_VU] [COOLDOWN_S]}"
N_MEASUREMENTS="${2:-7}"
REFERENCE_VUS="${3:-16}"
ITER_PER_VU="${4:-2000}"
COOLDOWN_S="${5:-10}"

cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE_FILE="../../docker-compose.yml"
RESULTS_DIR="../../results"
CONTAINER_OUT_DIR="/results"

# "run --rm" starts only the k6 one-off container -- k6 has no depends_on, so
# compose will not bring python-service/transaction-service up for it. If
# they're not already running (or transaction-service hasn't been created yet
# because it's still waiting on python-service's healthcheck), every request
# fails DNS resolution for "java" instantly, and that looks nothing like a
# real network problem: check for it up front instead of burning a measurement.
for svc in python-service transaction-service; do
  cid=$(docker compose -f "$COMPOSE_FILE" ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    echo "[!] Service '${svc}' has no running container under ${COMPOSE_FILE}." >&2
    echo "    Bring the stack up first: docker compose -f docker-compose.yml up -d --wait" >&2
    exit 1
  fi
  state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  if [ "$state" != "running" ]; then
    echo "[!] Service '${svc}' container is '${state}', not running." >&2
    echo "    Bring the stack up first: docker compose -f docker-compose.yml up -d --wait" >&2
    exit 1
  fi
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown")
  if [ "$health" != "none" ] && [ "$health" != "healthy" ]; then
    echo "[!] Service '${svc}' container is running but health is '${health}', not 'healthy'." >&2
    echo "    Wait for it, or bring the stack up with: docker compose -f docker-compose.yml up -d --wait" >&2
    exit 1
  fi
done

THROUGHPUTS_FILE="$(mktemp)"
trap 'rm -f "$THROUGHPUTS_FILE"' EXIT

for i in $(seq 1 "$N_MEASUREMENTS"); do
  raw_name="drift_probe_${TIER}_vus${REFERENCE_VUS}_m${i}.json"
  echo "[calibrate] measurement ${i}/${N_MEASUREMENTS}: tier=${TIER} VUS=${REFERENCE_VUS}..."
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    -e TARGET="$TIER" -e VUS="$REFERENCE_VUS" -e ITERATIONS_PER_VU="$ITER_PER_VU" \
    -e PHASE=scan -e REP="drift_probe_${i}" \
    k6 run /scripts/run-target.js --out "json=${CONTAINER_OUT_DIR}/${raw_name}"

  throughput=$(python3 - "${RESULTS_DIR}/${raw_name}" <<'PYEOF'
import json, re, sys
from datetime import datetime

def parse_iso(ts):
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts)
    return datetime.fromisoformat(ts)

times = []
total = 0
with open(sys.argv[1]) as f:
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
        tags = obj["data"].get("tags") or {}
        if tags.get("phase") != "scan":
            continue
        total += 1
        # Same filter analyze-results.py applies before any throughput calc: an
        # all-failed cell (e.g. DNS/connection errors) still emits points, and
        # counting those in would report a "throughput" for traffic that never
        # reached the service.
        if tags.get("status") == "200":
            times.append(parse_iso(obj["data"]["time"]))

n = len(times)
if total == 0:
    sys.exit("no phase=scan http_req_duration points at all -- did the cell run?")
if n == 0:
    sys.exit(f"all {total} phase=scan point(s) failed (status != 200) -- 0% success, "
             f"nothing to measure throughput from. Check the k6 container's own output "
             f"above for the actual error.")
if n < 2:
    sys.exit(f"only {n} successful (status=200) point(s) out of {total} -- need at least "
             f"2 to measure a time span")
duration = (max(times) - min(times)).total_seconds()
if duration <= 0:
    sys.exit("points share one timestamp -- cannot compute throughput")
# N completion timestamps bound N-1 inter-completion intervals, so the rate over that
# span is (N-1)/span -- same convention as analyze-results.py's _throughput_reqs_per_s.
print((n - 1) / duration)
PYEOF
  )
  echo "  throughput=${throughput} req/s"
  echo "$throughput" >> "$THROUGHPUTS_FILE"
  rm -f "${RESULTS_DIR}/${raw_name}"

  if [ "$i" -lt "$N_MEASUREMENTS" ]; then
    sleep "$COOLDOWN_S"
  fi
done

echo ""
python3 - "$THROUGHPUTS_FILE" "$N_MEASUREMENTS" <<'PYEOF'
import statistics, sys

values = [float(line) for line in open(sys.argv[1]) if line.strip()]
n_expected = int(sys.argv[2])
if len(values) != n_expected:
    sys.exit(f"expected {n_expected} measurements, got {len(values)}")

mean = statistics.mean(values)
stdev = statistics.stdev(values) if len(values) > 1 else 0.0
spread_pct = (max(values) - min(values)) / mean * 100

print(f"measurements: {[round(v, 1) for v in values]}")
print(f"mean={mean:.1f} req/s  stdev={stdev:.1f} req/s ({stdev / mean * 100:.1f}%)  "
      f"range={min(values):.1f}-{max(values):.1f} req/s (spread={spread_pct:.1f}%)")
print()
print("A calibration derived from one measurement sizes every rep's iteration count to "
      "within roughly this spread of the intended cell duration. Whether that is tight "
      "enough to calibrate once per target instead of once per rep is a threshold call, "
      "not something this probe decides.")
PYEOF
