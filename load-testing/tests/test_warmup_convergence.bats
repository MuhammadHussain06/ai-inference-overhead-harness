#!/usr/bin/env bats
# Unit tests for converge_warmup()'s convergence gate, embedded in run-suite.sh and
# duplicated in run-ablation.sh. The gate decides when warm-up stops, so a gate that
# is too strict burns MAX_WARMUP_CHUNKS on an already-settled stack and one that is
# too loose hands the measured phase a target that is still moving. Neither shows up
# as a failure anywhere -- table0 only reports the drift after the fact.
#
# The gate's decision lives in a python3 heredoc that is only reachable by running
# the whole function, so these tests source the real function and constants out of
# the live script text (never a copy) and stub the three things it calls out to:
# k6_run, finalize_result and check_thermal_safety. k6_run replays a crafted JSON
# chunk instead of starting a container, following the same PATH/stub approach
# test_jvm_pins.bats and test_load_testing_helpers.bats use for docker.

setup_file() {
  export SUITE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-suite.sh"
  export ABLATION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-ablation.sh"

  # Emits k6-shaped http_req_duration points into one chunk file. Each spec is
  # "tier:status:value:count"; specs are laid down in order and timestamps advance
  # 1ms per point from start_index, so chunks appended end to end stay in time
  # order and the gate's per-tier sort sees the series as written.
  cat > "${BATS_FILE_TMPDIR}/gen_chunk.py" <<'EOF'
import sys

out, start = sys.argv[1], int(sys.argv[2])
i = start
with open(out, "w") as f:
    for spec in sys.argv[3:]:
        tier, status, value, count = spec.split(":")
        for _ in range(int(count)):
            us = i * 1000
            ts = "2026-01-01T00:%02d:%02d.%06dZ" % (us // 60000000, us // 1000000 % 60,
                                                    us % 1000000)
            f.write('{"type":"Point","metric":"http_req_duration","data":{"time":"%s",'
                    '"value":%s,"tags":{"tier":"%s","status":"%s","phase":"warmup"}}}\n'
                    % (ts, value, tier, status))
            i += 1
EOF

  # The gate's constants and the function itself, taken from the live script so
  # these run at the real WARMUP_WINDOW rather than a shrunken one. A window too
  # small for the request rate reads sampling noise as drift, which is why the
  # window size is part of what is under test here.
  extract_gate() {
    grep -E '^(WARMUP_CHUNK_DURATION_S|MAX_WARMUP_CHUNKS|WARMUP_WINDOW|WARMUP_TAIL_TOLERANCE_PCT|WARMUP_TAIL_ABS_FLOOR_MS)=' "$1"
    awk '/^converge_warmup\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
  }
  export -f extract_gate

  # Just the python3 heredoc body, for comparing the two scripts' copies.
  extract_gate_python() {
    awk '/^converge_warmup\(\) \{/ { f = 1 } f && /<<.PYEOF./ { p = 1; next }
         p && /^PYEOF$/ { exit } p { print }' "$1"
  }
  export -f extract_gate_python
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="${WORKDIR}/fixtures"
  RAW_RESULTS_DIR="${WORKDIR}/raw"
  mkdir -p "$FIXTURE_DIR" "$RAW_RESULTS_DIR"
  K6_LOG="${WORKDIR}/k6_calls.log"
  FINALIZE_LOG="${WORKDIR}/finalized.log"
  : > "$K6_LOG"
  : > "$FINALIZE_LOG"
  K6_CHUNK=0

  # Stands in for the container run: records the invocation and writes this
  # chunk's fixture to wherever --out json=/results/raw/<name> pointed. A chunk
  # with no fixture writes an empty file, which is how a target that stops
  # producing data is represented.
  k6_run() {
    printf '%s\n' "$*" >> "$K6_LOG"
    K6_CHUNK=$((K6_CHUNK + 1))
    local arg out_name=""
    for arg in "$@"; do
      case "$arg" in json=/results/raw/*) out_name="${arg#json=/results/raw/}" ;; esac
    done
    if [ -r "${FIXTURE_DIR}/chunk${K6_CHUNK}.json" ]; then
      cp "${FIXTURE_DIR}/chunk${K6_CHUNK}.json" "${RAW_RESULTS_DIR}/${out_name}"
    else
      : > "${RAW_RESULTS_DIR}/${out_name}"
    fi
  }
  finalize_result() { printf '%s\n' "$1" >> "$FINALIZE_LOG"; }
  check_thermal_safety() { :; }

  extract_gate "$SUITE_SH" > "${WORKDIR}/gate.sh"
  source "${WORKDIR}/gate.sh"
}

# Writes one chunk fixture. Usage: chunk <n> <start_index> <tier:status:value:count>...
chunk() {
  local n="$1" start="$2"; shift 2
  python3 "${BATS_FILE_TMPDIR}/gen_chunk.py" "${FIXTURE_DIR}/chunk${n}.json" "$start" "$@"
}

k6_call_count() { grep -c . "$K6_LOG"; }

# --- the constants the gate is tuned to ---

@test "the gate's window is large enough not to read per-request noise as drift" {
  # Raised from 100 after a 100-point window reported spurious non-convergence on
  # already-stable targets. analyze-results.py's table0 must report the same
  # verdict, so its window_size default is pinned to this value in the pytest suite.
  [ "$WARMUP_WINDOW" = "500" ]
  [ "$WARMUP_TAIL_TOLERANCE_PCT" = "5.0" ]
  [ "$WARMUP_TAIL_ABS_FLOOR_MS" = "0.25" ]
  [ "$MAX_WARMUP_CHUNKS" = "4" ]
  [ "$WARMUP_CHUNK_DURATION_S" = "15" ]
}

@test "run-ablation.sh's duplicated gate decides identically to run-suite.sh's" {
  # The two copies are maintained by hand; a divergence would silently give the
  # ablation a different steady-state definition from the main suite.
  [ "$(extract_gate_python "$SUITE_SH")" = "$(extract_gate_python "$ABLATION_SH")" ]
  [ "$(extract_gate "$SUITE_SH" | grep -E '^[A-Z_]+=')" \
    = "$(extract_gate "$ABLATION_SH" | grep -E '^[A-Z_]+=')" ]
}

# --- the tail comparison ---

@test "a flat tail converges on the first chunk" {
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
  [ "$(k6_call_count)" = "1" ]
}

@test "a tail still drifting on both bounds never converges" {
  # Prev window 10ms, last window 20ms: 100% drift and a 10ms gap fail the
  # percentage tolerance and the absolute floor alike.
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
  [ "$(k6_call_count)" = "4" ]
}

@test "the absolute floor admits a sub-millisecond target the percentage bound rejects" {
  # 0.20ms -> 0.40ms is a 100% drift but a 0.20ms gap: well inside timer and
  # scheduler jitter, and exactly the settled mock/calibration target a
  # percentage-only bound would hold warm-up open on forever.
  chunk 1 0 "mock:200:0.20:1000" "mock:200:0.40:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

@test "the percentage tolerance admits a slow target the absolute floor rejects" {
  # 100ms -> 102ms is a 2ms gap, far above the floor, but only 2% of the target's
  # own latency scale -- the bound the floor was added alongside, not in place of.
  chunk 1 0 "28:200:100.0:1000" "28:200:102.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

# --- the joint condition across tiers ---

@test "one lagging tier blocks the chunk that every other tier passed" {
  # mock is flat from chunk 1; tier 28 only settles in chunk 2. Stopping at chunk
  # 1 would hand the measured phase a target that was still moving, which is the
  # masking the per-tier grouping exists to prevent.
  chunk 1 0 "mock:200:0.50:1500" "28:200:10.0:1000" "28:200:20.0:500"
  chunk 2 3000 "mock:200:0.50:1500" "28:200:20.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 2 chunk(s)"* ]]
  [ "$(k6_call_count)" = "2" ]
}

# --- what the gate refuses to read ---

@test "non-200 points are excluded from the tail comparison" {
  # The 200 series is flat throughout; the failed requests in the middle would
  # dominate the penultimate window and read as drift if they were counted.
  chunk 1 0 "28:200:10.0:1000" "28:0:900.0:250" "28:200:10.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

@test "a warm-up in which every request failed never converges" {
  chunk 1 0 "28:503:900.0:2000"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
}

@test "a tier short of three windows does not converge" {
  # One point below 3 * WARMUP_WINDOW: there is no penultimate window to compare
  # against, so "no drift measured" must not be read as "no drift".
  chunk 1 0 "28:200:10.0:1499"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
  [ "$(k6_call_count)" = "4" ]
}

# --- the result the gate leaves behind ---

@test "chunks are concatenated into one finalized file for the target" {
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  chunk 2 3000 "28:200:20.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [ "$(cat "$FINALIZE_LOG")" = "warmup_scan_rep1.json" ]
  [ ! -e "${RAW_RESULTS_DIR}/warmup_scan_rep1_combined.json" ]
  [ "$(grep -c . "${RAW_RESULTS_DIR}/warmup_scan_rep1.json")" = "3000" ]
}

# --- the fixed-iteration escape hatch ---

@test "WARMUP_ITERATIONS_PER_TARGET bypasses the gate for a single fixed pass" {
  # What keeps the smoke test and every fault-injection case fast: one pass, no
  # chunking, no convergence check at all.
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 WARMUP_ITERATIONS_PER_TARGET=50 REP=1
  [ "$status" -eq 0 ]
  [ "$(k6_call_count)" = "1" ]
  [[ "$output" != *"converged"* ]]
  [ "$(cat "$FINALIZE_LOG")" = "warmup_scan_rep1.json" ]
}

# --- what warm-up.js does with the env the gate sends it ---

# k6 normally runs containerized, so a host that can run the rest of this file may
# not have the binary; the scenario config is only inspectable where it does.
require_k6() {
  command -v k6 >/dev/null 2>&1 || skip "k6 is not on PATH (the suite runs it containerized)"
}

# One target's resolved scenario, as k6 itself builds it from warm-up.js's options.
scenario_field() {
  k6 inspect "$@" "$(dirname "$SUITE_SH")/warm-up.js" \
    | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["scenarios"]["warm_28"]))'
}

@test "warm-up.js defaults to constant-vus cut at the chunk duration with no drain" {
  # gracefulStop '0s' is what the tail comparison depends on: a staggered per-VU
  # drain thins concurrency during the grace window, and the thinner load reads as
  # fast, settled latency when it is really just fewer VUs contending.
  require_k6
  run scenario_field -e WARMUP_DURATION_S=15
  [ "$status" -eq 0 ]
  [[ "$output" == *'"executor": "constant-vus"'* ]]
  [[ "$output" == *'"gracefulStop": "0s"'* ]]
  [[ "$output" == *'"duration": "15s"'* ]]
}

@test "WARMUP_ITERATIONS_PER_TARGET selects the fixed-count executor instead" {
  # The bypass path: a fixed total budget split across VUS, bounded by maxDuration
  # rather than run to a wall clock. Nothing checks its tail, so it carries no
  # gracefulStop override.
  require_k6
  run scenario_field -e WARMUP_ITERATIONS_PER_TARGET=50 -e WARMUP_VUS=5
  [ "$status" -eq 0 ]
  [[ "$output" == *'"executor": "per-vu-iterations"'* ]]
  [[ "$output" == *'"iterations": 10'* ]]
  [[ "$output" != *'"duration"'* ]]
}

@test "the gated path drives warm-up.js by duration and the bypass does not" {
  # warm-up.js switches executors on WARMUP_ITERATIONS_PER_TARGET: constant-vus
  # with gracefulStop '0s' when it is unset, per-vu-iterations when it is set.
  # Sending WARMUP_DURATION_S on the gated path is what selects the former, whose
  # hard cut keeps a staggered VU drain from reading as converged latency.
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$(cat "$K6_LOG")" == *"WARMUP_DURATION_S=15"* ]]
  [[ "$(cat "$K6_LOG")" != *"WARMUP_ITERATIONS_PER_TARGET"* ]]

  : > "$K6_LOG"
  K6_CHUNK=0
  run converge_warmup "warmup_scan_rep2" WARMUP_VUS=5 WARMUP_ITERATIONS_PER_TARGET=50 REP=2
  [ "$status" -eq 0 ]
  [[ "$(cat "$K6_LOG")" != *"WARMUP_DURATION_S"* ]]
}
