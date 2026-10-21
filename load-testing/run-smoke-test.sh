#!/usr/bin/env bash
set -euo pipefail

# Pipeline check, not data: a small slice of run-suite.sh, one deliberately unsustainable
# open-loop cell to confirm dropped_iterations fires, a one-rep composition check, a
# two-cell ablation slice, and both analysis scripts, so every path runs end to end before
# a full run. Needs a prepared host (prepare-host.sh), like every harness script.

cd "$(dirname "${BASH_SOURCE[0]}")"
. lib/run-layout.sh
HOST_LABEL=$(run_host_label)

# Each harness script archives this host's earlier runs of its kind at start, so the one
# match left afterwards is the run it just made.
latest_run_dir() {
  local dirs=(../results/"${1}_${HOST_LABEL}"_*)
  [ -d "${dirs[-1]}" ] || { echo "[!] No ${1} run directory for host ${HOST_LABEL} under ../results." >&2; exit 1; }
  printf '%s' "${dirs[-1]}"
}

echo "[*] Smoke test 1/5: main suite -- calibration + tier 28, VUS 1 & 32, 2 reps"
TARGETS_OVERRIDE="calibration 28" \
CONCURRENCY_OVERRIDE="1 32" \
REPS_BASELINE_OVERRIDE=2 \
REPS_SCAN_OVERRIDE=2 \
BASELINE_ITERATIONS_OVERRIDE=20 \
SCAN_ITERATIONS_PER_VU_OVERRIDE=10 \
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
./run-suite.sh
SUITE_DIR=$(latest_run_dir suite)

echo "[*] Smoke test 2/5: deliberate over-rate open-loop check (expect dropped_iterations > 0)"
# Through run-openloop.sh, so the smoke test exercises the same recorded-settings startup,
# guards, restart, warm-up and finalize path as a real open-loop check, at a rate no host
# sustains: one rep, a short cell and the fixed-iteration warm-up, as for the suite slice.
OPENLOOP_RATES=5000 OPENLOOP_DURATION=20s OPENLOOP_PRE_ALLOCATED_VUS=32 OPENLOOP_MAX_VUS=64 \
OPENLOOP_REPS=1 WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
OPENLOOP_PHASE=smoke-openloop ./run-openloop.sh "$SUITE_DIR"
SMOKE_FILE="${SUITE_DIR}/openloop_28_rate5000_rep1.json.gz"

# table7 excludes phase=smoke-openloop on purpose (see analyze_openloop_check()), so
# it will never report this cell -- checked directly against the file instead.
SMOKE_DROPPED=$(python3 - "$SMOKE_FILE" <<'PYEOF'
import gzip, json, sys
n = 0
with gzip.open(sys.argv[1], "rt") as f:
    for line in f:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "Point" and obj.get("metric") == "dropped_iterations":
            n += obj.get("data", {}).get("value", 0)
print(int(n))
PYEOF
)
if [ "$SMOKE_DROPPED" -gt 0 ]; then
  echo "  [+] smoke-openloop: ${SMOKE_DROPPED} dropped_iterations recorded (RATE=5000 was, as intended, unsustainable)."
else
  echo "  [!] smoke-openloop: 0 dropped_iterations at RATE=5000 -- the open-loop executor did not detect the overload. Investigate before trusting the real suite's own open-loop checks." >&2
fi

# Deleted even though table7 excludes its phase, so the run directory holds no smoke cell.
rm -f "$SMOKE_FILE"

echo "[*] Smoke test 3/5: one-rep predict_proba composition check (expect a schema-2 predict_composition.json)"
COMPOSITION_REPS=1 COMPOSITION_N=50 COMPOSITION_WARMUP=5 ./run-predict-composition.sh "$SUITE_DIR"
COMPOSITION_FILE="${SUITE_DIR}/predict_composition.json"
python3 - "$COMPOSITION_FILE" <<'PYEOF'
import json, sys
report = json.load(open(sys.argv[1]))
reps = report.get("reps") or []
tiers = sorted(int(t["tier"]) for t in (reps[0].get("tiers") if reps else []) or [])
if report.get("schema") != 2 or report.get("n_reps") != 1 or len(reps) != 1 or tiers != [5, 10, 20, 28]:
    sys.exit(f"[!] {sys.argv[1]}: expected schema 2 with one rep of tiers 5/10/20/28, got schema="
             f"{report.get('schema')} n_reps={report.get('n_reps')} tiers={tiers}")
print(f"  [+] composition: schema 2, 1 rep, tiers {tiers}, CPU quota "
      f"{(reps[0].get('cpu_quota') or {}).get('status', 'unchecked')}.")
PYEOF
# Deleted like the smoke cell above, so table 9 never reports a 50-call smoke measurement.
rm -f "$COMPOSITION_FILE"
rm -rf "${SUITE_DIR}/predict_composition_reps"

echo "[*] Smoke test 4/5: ablation slice -- exercises the cpuset arm's multi-range values"
# The cpuset arm is the one whose cell values are cpuset strings rather than integers,
# so it is the arm that catches a parsing regression in analyze-ablation.py.
ABLATION_CELLS_OVERRIDE="cpuset:0-1:0-1:2.0:3:40 cpuset:0-1,4-5,8-9:0-1,4-5,8-9:6.0:3:40" \
REPS_ABLATION_OVERRIDE=2 \
ABLATION_VUS_OVERRIDE=8 \
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=20 \
ABLATION_CALIB_ITER_PER_VU_OVERRIDE=20 \
ABLATION_CALIB_TARGET_DURATION_S_OVERRIDE=5 \
./run-ablation.sh
ABLATION_DIR=$(latest_run_dir ablation)

echo "[*] Smoke test 5/5: both analysis scripts, on this smoke test's two runs only"
# Same venv setup.sh builds (PEP 668 blocks a bare pip install/system python3 here).
../analysis/venv/bin/python3 ../analysis/analyze-results.py --results-dir "$SUITE_DIR"
../analysis/venv/bin/python3 ../analysis/analyze-ablation.py --results-dir "$ABLATION_DIR"

echo "[+] Smoke test complete. Before trusting this run, check, in ${SUITE_DIR} and ${ABLATION_DIR}:"
echo "    run_failures_log.txt, ablation_run_failures_log.txt, openloop_failures_log.txt and"
echo "    composition_failures_log.txt (all empty)"
echo "    cpu_pin_check_log.txt, openloop_cpu_pin_check_log.txt and ablation_cpu_pin_check_log.txt,"
echo "    incl. the smt_check lines, and the recorded_setting lines of the open-loop one"
echo "    env_trace_log.txt and ablation_env_trace_log.txt (cell_start/cell_end, cell_freq and"
echo "    thermal_check lines for every cell), and both *calibration_log.txt files"
echo "    power_state in both metadata files: the state prepare-host.sh set, turbo as required"
echo "    connection_placement_log.txt: placement lines for every cell, not placement_unavailable"
echo "    the [+]/[!] smoke-openloop line printed above (dropped_iterations at RATE=5000);"
echo "    table7 itself will not show this cell -- it excludes phase=smoke-openloop on purpose"
echo "    table_ablation_decomposition lists both cpuset values, ordered by logical-CPU count"
echo ""
echo "    Expected here: both table0s list every target as 'fewer than three windows'. The"
echo "    convergence check needs three windows of at least 500 requests each, and this run"
echo "    sends about 20 per target -- the smoke test being small, not a pipeline failure."
echo "    The ablation tables carry no meaningful statistics at 2 reps either; the point is"
echo "    that they render at all."