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
./run-suite.sh

echo "[*] Deliberate over-rate open-loop check (expect dropped_iterations > 0)"
BASE_URL="${BASE_URL:-http://localhost:8080/api/v1/transactions}" \
TARGET=28 RATE=5000 TIME_UNIT=1s DURATION=20s \
PRE_ALLOCATED_VUS=32 MAX_VUS=64 PHASE=smoke-openloop REP=1 \
  k6 run --out json=../results/openloop_28_smoke.json run-target-openloop.js

echo "[*] Running analyze-results.py -- confirm it completes and table7/figure7 appear"
python3 ../analysis/analyze-results.py

echo "[+] Smoke test complete. Check ../results/run_failures_log.txt and"
echo "    ../results/cpu_pin_check_log.txt before trusting this run, then"
echo "    confirm table7_openloop_validity_check shows Dropped iterations > 0"
echo "    for the smoke-openloop cell. If all clean, proceed to the full suite."