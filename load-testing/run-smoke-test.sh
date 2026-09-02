#!/usr/bin/env bash
set -euo pipefail

# First-pass pipeline check, not a real data run. Runs a small slice of
# run-suite.sh (2 targets x 2 concurrency levels x 2 reps, few iterations),
# then one deliberately over-rate open-loop check to confirm
# dropped_iterations fires, then analyze-results.py. Confirms the pipeline
# executes end to end -- including table7/figure7 -- before committing to
# the full multi-day suite.

    cd "$(dirname "${BASH_SOURCE[0]}")"

echo "[*] Smoke test: calibration + tier 28, VUS 1 & 32, 2 reps, small iteration counts"
TARGETS_OVERRIDE="calibration 28" \
CONCURRENCY_OVERRIDE="1 32" \
REPS_BASELINE_OVERRIDE=2 \
REPS_SCAN_OVERRIDE=2 \
BASELINE_ITERATIONS_OVERRIDE=20 \
SCAN_ITERATIONS_PER_VU_OVERRIDE=10 \
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
./run-suite.sh

echo "[*] Deliberate over-rate open-loop check (expect dropped_iterations > 0)"
# Runs in container to mirror run-suite.sh k6_run() without host k6 dependencies.
# Uses docker-compose BASE_URL and volume mounts (./load-testing:/scripts, ./results:/results).
docker compose -f ../docker-compose.yml --profile loadgen run --rm -T \
  -e TARGET=28 -e RATE=5000 -e TIME_UNIT=1s -e DURATION=20s \
  -e PRE_ALLOCATED_VUS=32 -e MAX_VUS=64 -e PHASE=smoke-openloop -e REP=1 \
  k6 run /scripts/run-target-openloop.js --out json=/results/openloop_28_smoke.json

echo "[*] Running analyze-results.py -- confirm it completes and table7/figure7 appear"
python3 ../analysis/analyze-results.py

echo "[+] Smoke test complete. Check ../results/run_failures_log.txt and"
echo "    ../results/cpu_pin_check_log.txt before trusting this run, then"
echo "    confirm table7_openloop_validity_check shows Dropped iterations > 0"
echo "    for the smoke-openloop cell. If all clean, proceed to the full suite."