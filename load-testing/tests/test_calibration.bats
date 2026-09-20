#!/usr/bin/env bats
# Unit tests for calibrate_target() in run-suite.sh and calibrate_ablation_cell() in
# run-ablation.sh. Both measure a target's real throughput at a reference VUS and
# derive the ITERATIONS_PER_VU that makes every concurrency level span the same
# wall-clock duration. The derivation is what keeps the per-vu-iterations taper a
# small tail rather than most of the cell, so an arithmetic slip there shortens or
# stretches cells silently -- nothing downstream reports the intended duration.
#
# Both functions are embedded in their scripts rather than in lib/, so each is
# sourced out of the live script text together with the constants it reads. k6_run
# and finalize_result are stubbed: finalize_result writes the crafted measurement
# gzip the derivation then reads back, standing in for the real filter-and-gzip step.

setup_file() {
  export SUITE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-suite.sh"
  export ABLATION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-ablation.sh"

  # n http_req_duration points spread evenly over duration_s, so the measured
  # throughput is exactly n/duration_s. Extra non-scan and non-latency points are
  # appended at the same timestamps: the derivation must ignore them rather than
  # count them as completed requests.
  cat > "${BATS_FILE_TMPDIR}/gen_calib.py" <<'EOF'
import sys

out, n, dur, phase = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
noise = sys.argv[5] == "noise"
step = dur / (n - 1) if n > 1 else 0.0
POINT = ('{"type":"Point","metric":"%s","data":{"time":"%s","value":1.0,'
         '"tags":{"phase":"%s","tier":"28","status":"200"}}}\n')
with open(out, "w") as f:
    for i in range(n):
        us = round(i * step * 1e6)
        ts = "2026-01-01T00:%02d:%02d.%06dZ" % (us // 60000000, us // 1000000 % 60,
                                                us % 1000000)
        f.write(POINT % ("http_req_duration", ts, phase))
        if noise:
            f.write(POINT % ("http_req_duration", ts, "warmup"))
            f.write(POINT % ("python_total_time_ms", ts, phase))
EOF

  # Constants plus the function, taken from the live script so the derivation runs
  # against the real reference VUS, target duration and concurrency levels.
  extract_calib() {
    grep -E '^(CALIB_VUS|CALIB_ITER_PER_VU|CALIB_TARGET_DURATION_S|CALIB_AFFECTED_LEVELS)=' "$1"
    grep -E '^declare -A CALIB_ITERATIONS_PER_VU$' "$1"
    awk '/^calibrate_target\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
  }
  export -f extract_calib

  extract_ablation_calib() {
    grep -E '^(ABLATION_TARGET|ABLATION_VUS|ABLATION_CALIB_ITER_PER_VU|ABLATION_CALIB_TARGET_DURATION_S)=' "$1"
    awk '/^calibrate_ablation_cell\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
  }
  export -f extract_ablation_calib
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  export RESULTS_DIR="${WORKDIR}/results"
  export FIXTURE="${WORKDIR}/measurement.json"
  mkdir -p "$RESULTS_DIR"
}

# Writes the measurement k6 would have produced. Usage: measurement <n> <duration_s> [phase] [noise]
measurement() {
  python3 "${BATS_FILE_TMPDIR}/gen_calib.py" "$FIXTURE" "$1" "$2" "${3:-scan}" "${4:-clean}"
}

# Builds a runnable harness around one extracted function. The suite runs under
# `set -euo pipefail`, so these do too -- a derivation that produces nothing must
# be seen failing the way it would fail mid-run, not under looser shell options.
harness() {
  local extractor="$1" script="$2" call="$3"
  {
    echo 'set -euo pipefail'
    echo 'k6_run() { :; }'
    # Same contract as the real one: report the reason, then stop the run.
    echo 'abort_suite() { local l="$1"; shift; echo "  [FATAL] ${l}: $*"; exit 1; }'
    # Stands in for the real filter-and-gzip step, using the same gzip module it does
    # rather than a gzip(1) the rest of the harness never requires.
    echo 'finalize_result() { python3 -c "import gzip,shutil,sys'
    echo 'shutil.copyfileobj(open(sys.argv[1],\"rb\"), gzip.open(sys.argv[2],\"wb\"))" \'
    echo '  "$FIXTURE" "${RESULTS_DIR}/${1}.gz"; }'
    "$extractor" "$script"
    echo "$call"
  } > "${WORKDIR}/harness.sh"
}

# --- calibrate_target: the derivation ---

@test "iterations per VU are derived so every level spans the target duration" {
  # 128 requests over 6s is 21.33 req/s; at CALIB_TARGET_DURATION_S=60 a cell needs
  # 1280 requests, split across each level's VUs.
  measurement 128 6.0 scan noise
  harness extract_calib "$SUITE_SH" 'calibrate_target 28 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=160 VUS16=80 VUS32=40 VUS64=20"* ]]
}

@test "the derived counts scale inversely with concurrency, not with throughput alone" {
  # Twice the throughput of the case above: every level's count doubles, and the
  # 8:1 ratio between the lowest and highest level is unchanged.
  measurement 256 6.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=320 VUS16=160 VUS32=80 VUS64=40"* ]]
}

@test "a target too slow to fill a cell still gets at least one iteration per VU" {
  # 4 requests over 120s rounds to zero iterations at every level; a VU given zero
  # iterations runs no requests at all and the cell produces nothing.
  measurement 4 120.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=1 VUS16=1 VUS32=1 VUS64=1"* ]]
}

# --- calibrate_target: no usable measurement ---

@test "a measurement with no scan points yields no iteration count and fails loudly" {
  # Silently falling through would leave the scan loop on SCAN_ITERATIONS_PER_VU's
  # flat fallback for a target whose throughput that value was never chosen for.
  measurement 128 6.0 warmup
  harness extract_calib "$SUITE_SH" 'calibrate_target 28 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"VUS8="* ]]
  [[ "$output" == *"[FATAL]"* ]]
  [[ "$output" == *"no iteration count derived"* ]]
}

@test "a failed calibration does not inherit the previous target's counts" {
  # CALIB_ITERATIONS_PER_VU is a global reused across targets. Carrying stale keys
  # into a target whose throughput they were never measured for would size every one
  # of its cells against another target, while the log reports them as calibrated.
  measurement 128 6.0 scan
  harness extract_calib "$SUITE_SH" 'calibrate_target 5 1'
  # Target 5 calibrates normally; the fixture is then replaced with one holding no
  # scan points, so target 28's calibration derives nothing.
  {
    cat "${WORKDIR}/harness.sh"
    echo 'python3 "${GEN}" "$FIXTURE" 128 6.0 warmup clean'
    echo 'calibrate_target 28 1'
  } > "${WORKDIR}/harness2.sh"
  GEN="${BATS_FILE_TMPDIR}/gen_calib.py" run bash "${WORKDIR}/harness2.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target=5 rep=1: VUS8=160"* ]]
  [[ "$output" != *"target=28 rep=1: VUS8=160"* ]]
  [[ "$output" == *"[FATAL]"* ]]
}

@test "a measurement whose requests share one timestamp yields no iteration count" {
  # Zero elapsed time is not zero throughput; deriving from it would divide by zero
  # or report an unbounded rate.
  measurement 128 0.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"VUS8="* ]]
}

# --- calibrate_ablation_cell: the same derivation at a single concurrency ---

@test "the ablation derives the same count run-suite.sh derives for its VUS" {
  # run-ablation.sh maintains its own copy of this arithmetic at a fixed
  # ABLATION_VUS=64; the same measured throughput must produce the same count the
  # main suite derives for VUS=64, or the two scan durations are not comparable.
  measurement 128 6.0 ablation-calib noise
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITERATIONS_PER_VU=20"* ]]
}

@test "the ablation clamps to one iteration per VU as well" {
  measurement 4 120.0 ablation-calib
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITERATIONS_PER_VU=1"* ]]
}

@test "an ablation measurement with no usable points yields no iteration count" {
  measurement 128 6.0 scan
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1 1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"ITERATIONS_PER_VU="* ]]
}
