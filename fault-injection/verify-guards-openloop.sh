#!/usr/bin/env bash
set -uo pipefail

# Fault injection for run-openloop.sh. Each case in cases/openloop/ patches one recorded
# setting in a copy of a finished suite run's metadata and passes only if the open-loop check rejects it
# through the expected guard (its tag in openloop_failures_log.txt) or refuses it before
# opening that log. Case 00 runs the unmodified copy and must complete clean.
#
# Usage: ./verify-guards-openloop.sh [SUITE_RUN_DIR]
#        (default: scratch/00-unmodified/results, left by ./verify-guards.sh)
#
# Each case writes only into its own run directory under scratch/openloop/<case>/.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
unset RUN_RESULTS_DIR

for _req_cmd in docker python3 timeout; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}." >&2
    exit 1
  fi
done

. ../load-testing/lib/host-provenance.sh
. ../load-testing/lib/power-state.sh
require_prepared_host "${REQUIRED_TURBO_OVERRIDE:-off}"
. lib/guard-cases.sh

CHECK_NAME="openloop"
SCRIPT="run-openloop.sh"
FAILURES_FILE="openloop_failures_log.txt"
# One short rep at a low explicit rate on the calibration target, with the fixed-iteration
# warm-up: the case slice exercises the startup and per-rep guards, not the measurement.
DEFAULT_ENV="OPENLOOP_TARGET=calibration OPENLOOP_RATES=20 OPENLOOP_DURATION=10s OPENLOOP_REPS=1
  OPENLOOP_PRE_ALLOCATED_VUS=8 OPENLOOP_MAX_VUS=16 OPENLOOP_COOLDOWN_S=1
  WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 OPENLOOP_PHASE=guard-check"

control_check() {
  [ -s openloop_calibration_rate20_rep1.json.gz ] && grep -q '^recorded_setting ' openloop_cpu_pin_check_log.txt
}

run_guard_cases "${1:-}"
