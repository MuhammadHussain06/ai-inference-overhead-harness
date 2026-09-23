#!/usr/bin/env bats
# Unit tests for the throughput calibration in run-suite.sh (calibrate_target(),
# calibrate_scan_targets(), use_calibration()) and run-ablation.sh
# (calibrate_ablation_cell(), calibrate_ablation_cells()). Calibration measures a
# target's real throughput at a reference VUS and derives the ITERATIONS_PER_VU that
# makes every concurrency level span the same wall-clock duration, once, before the
# reps that reuse it. The derivation is what keeps the per-vu-iterations taper a small
# tail rather than most of the cell, so an arithmetic slip there shortens or stretches
# cells silently -- nothing downstream reports the intended duration.
#
# The functions are embedded in their scripts rather than in lib/, so each is sourced
# out of the live script text together with the constants it reads. k6_run and
# finalize_result are stubbed: finalize_result writes the crafted measurement gzip the
# derivation then reads back, standing in for the real filter-and-gzip step.

setup_file() {
  export SUITE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-suite.sh"
  export ABLATION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-ablation.sh"

  # n http_req_duration points spread evenly over duration_s, so the measured
  # throughput is exactly (n-1)/duration_s (n timestamps bound n-1 intervals; see
  # _throughput_reqs_per_s in analyze-results.py for the same convention). Extra
  # non-scan and non-latency points are appended at the same timestamps: the
  # derivation must ignore them rather than count them as completed requests.
  # http_status defaults to "200"; a failed-request fixture passes "0" so tests
  # can assert the derivation ignores points that never reached the service.
  cat > "${BATS_FILE_TMPDIR}/gen_calib.py" <<'EOF'
import sys

out, n, dur, phase = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
noise = sys.argv[5] == "noise"
http_status = sys.argv[6] if len(sys.argv) > 6 else "200"
step = dur / (n - 1) if n > 1 else 0.0
POINT = ('{"type":"Point","metric":"%s","data":{"time":"%s","value":1.0,'
         '"tags":{"phase":"%s","tier":"28","status":"%s"}}}\n')
with open(out, "w") as f:
    for i in range(n):
        us = round(i * step * 1e6)
        ts = "2026-01-01T00:%02d:%02d.%06dZ" % (us // 60000000, us // 1000000 % 60,
                                                us % 1000000)
        f.write(POINT % ("http_req_duration", ts, phase, http_status))
        if noise:
            f.write(POINT % ("http_req_duration", ts, "warmup", http_status))
            f.write(POINT % ("python_total_time_ms", ts, phase, http_status))
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

  # The calibration passes, with everything they call except the derivation stubbed
  # to a log line, so a test sees the order the pass runs its steps in.
  extract_suite_pass() {
    extract_calib "$1"
    grep -E '^declare -A CALIB_CACHE$' "$1"
    for fn in calibrate_scan_targets use_calibration shuffled; do
      awk -v name="$fn" '$0 ~ "^" name "\\(\\) \\{" { f = 1 } f { print } f && /^}/ { exit }' "$1"
    done
    for fn in record_env_sample restart_stack wait_for_ready verify_cpu_pinning verify_jvm_flag_pins \
              verify_tiers verify_tiers_runtime verify_jvm_thread_pins check_thermal_safety; do
      echo "${fn}() { echo \"step ${fn} \$*\"; }"
    done
    echo 'converge_warmup() { echo "step converge_warmup $1"; }'
    echo 'sleep() { :; }'
  }
  export -f extract_suite_pass

  extract_ablation_pass() {
    extract_ablation_calib "$1"
    grep -E '^declare -A ABLATION_CALIB_CACHE$' "$1"
    awk '/^calibrate_ablation_cells\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
    for fn in record_env_sample verify_smt_isolation verify_service_cpuset restart_stack wait_for_ready \
              verify_cpu_pinning verify_jvm_flag_pins verify_tiers_and_limiter verify_tiers_runtime \
              verify_jvm_thread_pins check_thermal_safety; do
      echo "${fn}() { echo \"step ${fn} \$*\"; }"
    done
    echo 'converge_warmup() { echo "step converge_warmup $1"; }'
    echo 'sleep() { :; }'
  }
  export -f extract_ablation_pass
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  export RESULTS_DIR="${WORKDIR}/results"
  export FIXTURE="${WORKDIR}/measurement.json"
  mkdir -p "$RESULTS_DIR"
}

# Writes the measurement k6 would have produced.
# Usage: measurement <n> <duration_s> [phase] [noise] [http_status]
measurement() {
  python3 "${BATS_FILE_TMPDIR}/gen_calib.py" "$FIXTURE" "$1" "$2" "${3:-scan}" "${4:-clean}" "${5:-200}"
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
  # 129 points span 128 intervals over 6s, 21.33 req/s; at CALIB_TARGET_DURATION_S=60
  # a cell needs 1280 requests, split across each level's VUs.
  measurement 129 6.0 scan noise
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=160 VUS16=80 VUS32=40 VUS64=20"* ]]
}

@test "the derived counts scale inversely with concurrency, not with throughput alone" {
  # Twice the throughput of the case above: every level's count doubles, and the
  # 8:1 ratio between the lowest and highest level is unchanged.
  measurement 257 6.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=320 VUS16=160 VUS32=80 VUS64=40"* ]]
}

@test "a target too slow to fill a cell still gets at least one iteration per VU" {
  # 4 requests over 120s rounds to zero iterations at every level; a VU given zero
  # iterations runs no requests at all and the cell produces nothing.
  measurement 4 120.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS8=1 VUS16=1 VUS32=1 VUS64=1"* ]]
}

# --- calibrate_target: no usable measurement ---

@test "a measurement with no scan points yields no iteration count and fails loudly" {
  # Silently falling through would leave the scan loop on SCAN_ITERATIONS_PER_VU's
  # flat fallback for a target whose throughput that value was never chosen for.
  measurement 128 6.0 warmup
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
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
  measurement 129 6.0 scan
  harness extract_calib "$SUITE_SH" 'calibrate_target 5'
  # Target 5 calibrates normally; the fixture is then replaced with one holding no
  # scan points, so target 28's calibration derives nothing.
  {
    cat "${WORKDIR}/harness.sh"
    echo 'python3 "${GEN}" "$FIXTURE" 129 6.0 warmup clean'
    echo 'calibrate_target 28'
  } > "${WORKDIR}/harness2.sh"
  GEN="${BATS_FILE_TMPDIR}/gen_calib.py" run bash "${WORKDIR}/harness2.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target=5: VUS8=160"* ]]
  [[ "$output" != *"target=28: VUS8=160"* ]]
  [[ "$output" == *"[FATAL]"* ]]
}

@test "a measurement whose requests share one timestamp yields no iteration count" {
  # Zero elapsed time is not zero throughput; deriving from it would divide by zero
  # or report an unbounded rate.
  measurement 128 0.0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"VUS8="* ]]
}

@test "a measurement whose points all failed yields no iteration count" {
  # Every point present and phase=scan, but status!=200 (DNS/connection failure,
  # timeout): the same "nothing usable" outcome as no scan points at all, not a
  # throughput -- and iteration counts -- derived from traffic that never reached
  # the service.
  measurement 129 6.0 scan clean 0
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"VUS8="* ]]
  [[ "$output" == *"[FATAL]"* ]]
  [[ "$output" == *"no iteration count derived"* ]]
}

# --- calibrate_ablation_cell: the same derivation at a single concurrency ---

@test "the ablation derives the same count run-suite.sh derives for its VUS" {
  # run-ablation.sh maintains its own copy of this arithmetic at ABLATION_VUS=64. 65
  # points over 1s are 64 intervals, 64 req/s: 3840 requests per 60s cell, 60 per VU
  # at VUS=64. A derivation using N/span instead would give 61, so both copies
  # agreeing on 60 pins the shared (N-1)/span convention, not just the rounding.
  measurement 65 1.0 scan
  harness extract_calib "$SUITE_SH" 'calibrate_target 28'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VUS64=60"* ]]

  measurement 65 1.0 ablation-calib
  harness extract_ablation_calib "$ABLATION_SH" 'calibrate_ablation_cell cpuset 0-1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITERATIONS_PER_VU=60"* ]]
}

@test "the ablation clamps to one iteration per VU as well" {
  measurement 4 120.0 ablation-calib
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ITERATIONS_PER_VU=1"* ]]
}

@test "an ablation measurement with no usable points yields no iteration count" {
  measurement 128 6.0 scan
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"ITERATIONS_PER_VU="* ]]
}

@test "an ablation measurement whose points all failed yields no iteration count" {
  measurement 128 6.0 ablation-calib clean 0
  harness extract_ablation_calib "$ABLATION_SH" \
    'calibrate_ablation_cell cpuset 0-1'
  run bash "${WORKDIR}/harness.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"ITERATIONS_PER_VU="* ]]
}

# --- the calibration passes: measured once, reused by every rep ---

@test "the scan calibration pass prepares the stack like a scan rep before measuring" {
  measurement 129 6.0
  harness extract_suite_pass "$SUITE_SH" 'calibrate_scan_targets'
  {
    echo 'TARGETS=(28); CONCURRENCY_LEVELS=(1 64); REPS_SCAN=2; COOLDOWN_S=0; MAX_VUS=64'
    echo 'WARMUP_ENV_ARGS=(); WARMUP_MAXVUS_ENV_ARGS=(); CALIB_LOG="${RESULTS_DIR}/calibration_log.txt"'
    cat "${WORKDIR}/harness.sh"
  } > "${WORKDIR}/pass.sh"
  run bash "${WORKDIR}/pass.sh"
  [ "$status" -eq 0 ]
  steps=$(grep -o '^step [a-z_]*' <<< "$output" | cut -d' ' -f2 | paste -sd' ' -)
  [ "$steps" = "record_env_sample restart_stack wait_for_ready verify_cpu_pinning verify_jvm_flag_pins verify_tiers converge_warmup verify_tiers_runtime verify_jvm_thread_pins converge_warmup check_thermal_safety record_env_sample" ]
  [[ "$output" == *"step converge_warmup calib_warmup_scan"* ]]
  [[ "$output" == *"step converge_warmup calib_warmup_scan_maxvus"* ]]
  [ "$(cat "${RESULTS_DIR}/calibration_log.txt")" = "calibration target=28 VUS8=160 VUS16=80 VUS32=40 VUS64=20" ]
}

@test "every scan rep reads back the counts the pass measured" {
  measurement 129 6.0
  harness extract_suite_pass "$SUITE_SH" 'calibrate_scan_targets
for rep in 1 2; do
  use_calibration 28
  echo "rep=${rep} VUS8=${CALIB_ITERATIONS_PER_VU[8]} VUS64=${CALIB_ITERATIONS_PER_VU[64]}"
done
use_calibration 5
echo "uncalibrated=${#CALIB_ITERATIONS_PER_VU[@]}"'
  {
    echo 'TARGETS=(28); CONCURRENCY_LEVELS=(8 64); REPS_SCAN=2; COOLDOWN_S=0; MAX_VUS=64'
    echo 'WARMUP_ENV_ARGS=(); WARMUP_MAXVUS_ENV_ARGS=(); CALIB_LOG="${RESULTS_DIR}/calibration_log.txt"'
    cat "${WORKDIR}/harness.sh"
  } > "${WORKDIR}/pass.sh"
  run bash "${WORKDIR}/pass.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rep=1 VUS8=160 VUS64=20"* ]]
  [[ "$output" == *"rep=2 VUS8=160 VUS64=20"* ]]
  # A target the pass never measured keeps the flat fallback rather than another's counts.
  [[ "$output" == *"uncalibrated=0"* ]]
  [ "$(grep -c 'calibrate] target=28: measuring' <<< "$output")" = "1" ]
}

@test "the scan calibration pass is skipped when no scan level is calibrated" {
  harness extract_suite_pass "$SUITE_SH" 'calibrate_scan_targets; echo "done"'
  {
    echo 'TARGETS=(28); CONCURRENCY_LEVELS=(1 2 4); REPS_SCAN=2; COOLDOWN_S=0; MAX_VUS=4'
    echo 'WARMUP_ENV_ARGS=(); WARMUP_MAXVUS_ENV_ARGS=(); CALIB_LOG="${RESULTS_DIR}/calibration_log.txt"'
    cat "${WORKDIR}/harness.sh"
  } > "${WORKDIR}/pass.sh"
  run bash "${WORKDIR}/pass.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "the ablation calibration pass measures each cell once at its own configuration" {
  measurement 129 6.0 ablation-calib
  harness extract_ablation_pass "$ABLATION_SH" 'calibrate_ablation_cells
echo "cached=${ABLATION_CALIB_CACHE[cpuset:0-1]}/${ABLATION_CALIB_CACHE[workers:1]}"'
  {
    echo 'CELLS=("cpuset:0-1:0-1:2.0:3:40" "workers:1:0-1,4-5:4.0:1:40"); COOLDOWN_S=0'
    echo 'WARMUP_ENV_ARGS=(); CALIB_LOG="${RESULTS_DIR}/ablation_calibration_log.txt"'
    cat "${WORKDIR}/harness.sh"
  } > "${WORKDIR}/pass.sh"
  run bash "${WORKDIR}/pass.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"step restart_stack 0-1 2.0 3 40"* ]]
  [[ "$output" == *"step restart_stack 0-1,4-5 4.0 1 40"* ]]
  [[ "$output" == *"step converge_warmup ablation_calib_warmup_cpuset_0-1"* ]]
  [[ "$output" == *"cached=20/20"* ]]
  [ "$(grep -c . "${RESULTS_DIR}/ablation_calibration_log.txt")" = "2" ]
  grep -qx "calibration arm=workers value=1 iterations_per_vu=20" "${RESULTS_DIR}/ablation_calibration_log.txt"
}
