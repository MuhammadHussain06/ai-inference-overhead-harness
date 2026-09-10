#!/usr/bin/env bash
set -euo pipefail

# First-pass pipeline check, not a real data run. Runs a small slice of run-suite.sh,
# one deliberately over-rate open-loop check to confirm dropped_iterations fires, a
# two-cell ablation slice, and both analysis scripts. Confirms every path executes end
# to end before committing to the full multi-day suite.

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "[*] Smoke test 1/4: main suite -- calibration + tier 28, VUS 1 & 32, 2 reps"
TARGETS_OVERRIDE="calibration 28" \
CONCURRENCY_OVERRIDE="1 32" \
REPS_BASELINE_OVERRIDE=2 \
REPS_SCAN_OVERRIDE=2 \
BASELINE_ITERATIONS_OVERRIDE=20 \
SCAN_ITERATIONS_PER_VU_OVERRIDE=10 \
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
./run-suite.sh

echo "[*] Smoke test 2/4: deliberate over-rate open-loop check (expect dropped_iterations > 0)"
# Runs in a container to mirror run-suite.sh's k6_run() without a host k6 install.
docker compose -f ../docker-compose.yml --profile loadgen run --rm -T \
  -e TARGET=28 -e RATE=5000 -e TIME_UNIT=1s -e DURATION=20s \
  -e PRE_ALLOCATED_VUS=32 -e MAX_VUS=64 -e PHASE=smoke-openloop -e REP=1 \
  k6 run /scripts/run-target-openloop.js --out json=/results/openloop_28_smoke.json

echo "[*] Smoke test 3/4: ablation slice -- exercises the cpuset arm's multi-range values"
# The cpuset arm is the one whose cell values are cpuset strings rather than integers,
# so it is the arm that catches a parsing regression in analyze-ablation.py.
ABLATION_CELLS_OVERRIDE="cpuset:0-1:0-1:2.0:3:40 cpuset:0-1,4-5,8-9:0-1,4-5,8-9:6.0:3:40" \
REPS_ABLATION_OVERRIDE=2 \
ABLATION_ITERATIONS_PER_VU_OVERRIDE=10 \
ABLATION_VUS_OVERRIDE=8 \
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
./run-ablation.sh

echo "[*] Smoke test 4/4: both analysis scripts"
# Same venv setup.sh builds (PEP 668 blocks a bare pip install/system python3 here).
../analysis/venv/bin/python3 ../analysis/analyze-results.py
../analysis/venv/bin/python3 ../analysis/analyze-ablation.py

echo "[+] Smoke test complete. Before trusting this run, check:"
echo "    ../results/run_failures_log.txt and ../results/ablation_run_failures_log.txt (both empty)"
echo "    ../results/cpu_pin_check_log.txt, incl. the smt_check line"
echo "    ../results/env_trace_log.txt"
echo "    table7_openloop_validity_check shows Dropped iterations > 0 for the smoke-openloop cell"
echo "    table_ablation_decomposition lists both cpuset values, ordered by core count"
echo ""
echo "    Expected here: table0 is skipped as empty. Its convergence check needs 300+"
echo "    warm-up requests per window and this run sends 20 -- that is the smoke test"
echo "    being small, not a pipeline failure. The ablation tables carry no meaningful"
echo "    statistics at 2 reps either; the point is that they render at all."