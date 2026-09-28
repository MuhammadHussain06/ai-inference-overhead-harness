#!/usr/bin/env bash
# Runs the whole design unattended: run-suite.sh, run-openloop.sh against that suite
# run, run-ablation.sh, then analyze-results.py and analyze-ablation.py on the two runs
# this invocation produced. START_AT=openloop|ablation|analysis resumes at that step
# against this host's latest runs.
#
# A suite failure stops the chain. A failed open-loop step is reported and the ablation
# still runs; a failed ablation skips its analysis. The exit status is non-zero if any
# step failed. Each step's output goes to results/logs/run-all_<UTC timestamp>/. An
# unprepared host (see prepare-host.sh) is refused before any step starts.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
. lib/run-layout.sh
. lib/host-provenance.sh
. lib/power-state.sh

STEPS=(suite openloop ablation analysis)
START_AT="${START_AT:-suite}"
START_INDEX=-1
for i in "${!STEPS[@]}"; do
  if [ "${STEPS[$i]}" = "$START_AT" ]; then START_INDEX=$i; fi
done
if [ "$START_INDEX" -lt 0 ]; then
  echo "[!] START_AT must be one of: ${STEPS[*]}" >&2
  exit 1
fi

LOG_DIR="../results/logs/run-all_$(run_timestamp)"
mkdir -p "$LOG_DIR"
LOG_DIR=$(cd "$LOG_DIR" && pwd)
PYTHON=../analysis/venv/bin/python3
[ -x "$PYTHON" ] || PYTHON=python3
export PYTHONUNBUFFERED=1

step() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "${LOG_DIR}/run-all.log"; }

# Each step checks the power state itself; checking here too stops an unattended chain at
# launch, with the reason in run-all.log, rather than after its first step fails.
if [ "$START_AT" != "analysis" ] && ! power_check=$(require_prepared_host "${REQUIRED_TURBO_OVERRIDE:-off}" 2>&1); then
  echo "$power_check" | tee -a "${LOG_DIR}/run-all.log" >&2
  exit 1
fi

runs() {
  local i
  for i in "${!STEPS[@]}"; do
    if [ "${STEPS[$i]}" = "$1" ] && [ "$i" -ge "$START_INDEX" ]; then return 0; fi
  done
  return 1
}

latest_run() {
  local dirs=(../results/"$1"_"$(run_host_label)"_*)
  if [ -d "${dirs[-1]}" ]; then (cd "${dirs[-1]}" && pwd); fi
}

step "run-all from ${START_AT}, commit $(git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)," \
     "logs in ${LOG_DIR}"
step "power state: $(power_state_snapshot)"

failed=0
if runs suite; then
  step "suite: start"
  if ! ./run-suite.sh > "${LOG_DIR}/suite.log" 2>&1 < /dev/null; then
    step "suite: FAILED (see suite.log); stopping"
    exit 1
  fi
  step "suite: done -> $(latest_run suite)"
fi

if runs openloop; then
  step "openloop: start"
  if ./run-openloop.sh "$(latest_run suite)" > "${LOG_DIR}/openloop.log" 2>&1 < /dev/null; then
    step "openloop: done"
  else
    step "openloop: FAILED (see openloop.log); continuing"
    failed=1
  fi
fi

ablation_ok=1
if runs ablation; then
  step "ablation: start"
  if ./run-ablation.sh > "${LOG_DIR}/ablation.log" 2>&1 < /dev/null; then
    step "ablation: done -> $(latest_run ablation)"
  else
    step "ablation: FAILED (see ablation.log); its analysis is skipped"
    ablation_ok=0
    failed=1
  fi
fi

step "analysis: start"
if ! "$PYTHON" ../analysis/analyze-results.py --results-dir "$(latest_run suite)" \
    > "${LOG_DIR}/analysis_suite.log" 2>&1 < /dev/null; then
  step "analysis: analyze-results.py exited non-zero (see analysis_suite.log)"
  failed=1
fi
if [ "$ablation_ok" -eq 1 ]; then
  if ! "$PYTHON" ../analysis/analyze-ablation.py --results-dir "$(latest_run ablation)" \
      > "${LOG_DIR}/analysis_ablation.log" 2>&1 < /dev/null; then
    step "analysis: analyze-ablation.py exited non-zero (see analysis_ablation.log)"
    failed=1
  fi
fi
step "run-all complete$([ "$failed" -eq 0 ] || echo ", with failures")"
exit "$failed"
