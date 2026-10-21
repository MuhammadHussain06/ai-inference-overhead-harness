#!/usr/bin/env bash
set -uo pipefail

# Fault injection for run-predict-composition.sh. Each case in cases/composition/ patches one
# recorded setting in a copy of a finished suite run's metadata, or sets up a host condition, and passes
# only if the composition check rejects it through the expected guard (its tag in
# composition_failures_log.txt) or refuses it before opening that log. Case 00 runs the
# unmodified copy and must write a schema-2 predict_composition.json.
#
# Usage: ./verify-guards-composition.sh [SUITE_RUN_DIR]
#        (default: scratch/00-unmodified/results, left by ./verify-guards.sh)
#
# Each case writes only into its own run directory under scratch/composition/<case>/.

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

CHECK_NAME="composition"
SCRIPT="run-predict-composition.sh"
FAILURES_FILE="composition_failures_log.txt"
# One small rep: the case slice exercises the preconditions and the in-container checks,
# not the measurement.
DEFAULT_ENV="COMPOSITION_REPS=1 COMPOSITION_N=50 COMPOSITION_WARMUP=5 COMPOSITION_COOLDOWN_S=1"

control_check() {
  python3 - predict_composition.json <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
reps = report.get("reps") or []
tiers = sorted(int(t["tier"]) for t in (reps[0].get("tiers") if reps else []) or [])
if report.get("schema") != 2 or report.get("n_reps") != 1 or tiers != [5, 10, 20, 28]:
    sys.exit(f"expected schema 2 with one rep of tiers 5/10/20/28, got schema={report.get('schema')} "
             f"n_reps={report.get('n_reps')} tiers={tiers}")
PY
}

run_guard_cases "${1:-}"
