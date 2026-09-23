#!/usr/bin/env bats
# Unit tests for converge_warmup(), the warm-up convergence gate in run-suite.sh and
# run-ablation.sh. The gate decides when warm-up stops, so a gate that is too strict
# burns MAX_WARMUP_CHUNKS on an already-settled stack and one that is too loose hands
# the measured phase a target that is still moving. Neither shows up as a failure
# anywhere -- table0 only reports the drift after the fact.
#
# The function and its constants are sourced out of the live script text (never a
# copy), and its criterion is the real lib/warmup_gate.py. filter_chunk and
# gzip_only are sourced the same way, since converge_warmup's output depends on
# their real behavior. Only k6_run, finalize_result and check_thermal_safety are
# stubbed: k6_run replays a crafted JSON chunk instead of starting a container.

setup_file() {
  export LOAD_TESTING_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export SUITE_SH="${LOAD_TESTING_DIR}/run-suite.sh"
  export ABLATION_SH="${LOAD_TESTING_DIR}/run-ablation.sh"

  # Emits k6-shaped http_req_duration points into one chunk file. Each spec is
  # "tier:status:value:count"; specs are laid down in order, one point every
  # STEP_MS milliseconds from start_index, so chunks appended end to end stay in
  # time order. The default 10 ms spacing puts 500 requests across 5 s, so the
  # gate's window is WARMUP_WINDOW requests exactly.
  cat > "${BATS_FILE_TMPDIR}/gen_chunk.py" <<'EOF'
import os, sys
from datetime import datetime, timedelta, timezone

out, start = sys.argv[1], int(sys.argv[2])
step_ms = float(os.environ.get("STEP_MS", "10"))
t0 = datetime(2026, 1, 1, tzinfo=timezone.utc)
i = start
with open(out, "w") as f:
    for spec in sys.argv[3:]:
        tier, status, value, count = spec.split(":")
        for _ in range(int(count)):
            ts = (t0 + timedelta(milliseconds=i * step_ms)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            f.write('{"metric":"http_req_duration","type":"Point","data":{"time":"%s",'
                    '"value":%s,"tags":{"tier":"%s","status":"%s","phase":"warmup"}}}\n'
                    % (ts, value, tier, status))
            i += 1
EOF

  extract_fn() {
    awk -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { f = 1 } f { print } f && /^}/ { exit }' "$1"
  }
  export -f extract_fn

  gate_constants() {
    grep -E '^(WARMUP_CHUNK_DURATION_S|MAX_WARMUP_CHUNKS|WARMUP_WINDOW|WARMUP_WINDOW_MIN_S|WARMUP_TAIL_TOLERANCE_PCT|WARMUP_TAIL_ABS_FLOOR_MS|WARMUP_TABLE)=' "$1"
  }
  export -f gate_constants
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  FIXTURE_DIR="${WORKDIR}/fixtures"
  RAW_RESULTS_DIR="${WORKDIR}/raw"
  RESULTS_DIR="${WORKDIR}/results"
  LIB_DIR="${LOAD_TESTING_DIR}/lib"
  mkdir -p "$FIXTURE_DIR" "$RAW_RESULTS_DIR" "$RESULTS_DIR"
  K6_LOG="${WORKDIR}/k6_calls.log"
  FINALIZE_LOG="${WORKDIR}/finalized.log"
  THERMAL_LOG="${WORKDIR}/thermal_calls.log"
  : > "$K6_LOG"
  : > "$FINALIZE_LOG"
  : > "$THERMAL_LOG"
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
  check_thermal_safety() { printf '%s\n' "$1" >> "$THERMAL_LOG"; }

  eval "$(grep -E '^KEEP_METRICS=' "$SUITE_SH")"
  eval "$(extract_fn "$SUITE_SH" filter_chunk)"
  eval "$(extract_fn "$SUITE_SH" gzip_only)"
  eval "$(gate_constants "$SUITE_SH")"
  eval "$(extract_fn "$SUITE_SH" converge_warmup)"
}

# Writes one chunk fixture. Usage: chunk <n> <start_index> <tier:status:value:count>...
chunk() {
  local n="$1" start="$2"; shift 2
  python3 "${BATS_FILE_TMPDIR}/gen_chunk.py" "${FIXTURE_DIR}/chunk${n}.json" "$start" "$@"
}

k6_call_count() { grep -c . "$K6_LOG"; }

# --- the constants the gate is tuned to ---

@test "the gate's constants are the documented ones and match lib/warmup_gate.py's defaults" {
  [ "$WARMUP_WINDOW" = "500" ]
  [ "$WARMUP_WINDOW_MIN_S" = "3" ]
  [ "$WARMUP_TAIL_TOLERANCE_PCT" = "5.0" ]
  [ "$WARMUP_TAIL_ABS_FLOOR_MS" = "0.25" ]
  [ "$MAX_WARMUP_CHUNKS" = "4" ]
  [ "$WARMUP_CHUNK_DURATION_S" = "15" ]
  # table0 falls back to the module's defaults for a run without recorded
  # parameters, so the two must name the same criterion.
  run python3 -c "
import sys; sys.path.insert(0, '${LIB_DIR}')
import warmup_gate as g
print(g.BASE_WINDOW, g.MIN_WINDOW_SPAN_S, g.TAIL_TOLERANCE_PCT, g.TAIL_ABS_FLOOR_MS)"
  [ "$output" = "500 3.0 5.0 0.25" ]
}

@test "run-ablation.sh's gate is identical to run-suite.sh's" {
  # The two copies are maintained by hand; a divergence would silently give the
  # ablation a different steady-state definition from the main suite.
  [ "$(extract_fn "$SUITE_SH" converge_warmup)" = "$(extract_fn "$ABLATION_SH" converge_warmup)" ]
  [ "$(gate_constants "$SUITE_SH" | grep -v '^WARMUP_TABLE=')" \
    = "$(gate_constants "$ABLATION_SH" | grep -v '^WARMUP_TABLE=')" ]
}

@test "both scripts resolve LIB_DIR to the lib directory the gate runs from" {
  for script in "$SUITE_SH" "$ABLATION_SH"; do
    grep -qx 'LIB_DIR="${PWD}/lib"' "$script"
  done
}

# --- the tail comparison ---

@test "a flat tail converges on the first chunk" {
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
  [ "$(k6_call_count)" = "1" ]
}

@test "a tail still drifting on both bounds never converges" {
  # Prev window 10ms, last window 20ms: 100% drift and a 10ms gap fail the
  # percentage tolerance and the absolute floor alike.
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
  [ "$(k6_call_count)" = "4" ]
}

@test "the absolute floor admits a sub-millisecond target the percentage bound rejects" {
  # 0.20ms -> 0.40ms is a 100% drift but a 0.20ms gap: inside timer and scheduler
  # jitter, and the settled mock/calibration case a percentage-only bound would
  # hold warm-up open on forever.
  chunk 1 0 "mock:200:0.20:1000" "mock:200:0.40:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=mock WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

@test "the percentage tolerance admits a slow target the absolute floor rejects" {
  # 100ms -> 102ms is a 2ms gap, far above the floor, but only 2% of the target's
  # own latency scale.
  chunk 1 0 "28:200:100.0:1000" "28:200:102.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

# --- the time-defined window ---

@test "a window spans at least WARMUP_WINDOW_MIN_S, so a sub-second blip is not drift" {
  # 1ms per point: 500 requests cover half a second. The last 500 are slower, which
  # a 500-request window would read as a 100% jump; the gate widens the window to
  # the first multiple of 500 spanning 3s, whose median the blip does not move.
  STEP_MS=1 chunk 1 0 "mock:200:10.0:11500" "mock:200:20.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=mock WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
  [[ "$output" == *"window=3500 (3.5s)"* ]]
}

@test "a sustained shift is still caught at a high request rate" {
  # Same rate, but the slower latency holds for the whole last window.
  STEP_MS=1 chunk 1 0 "mock:200:10.0:8000" "mock:200:20.0:4000"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=mock WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"window=3500"*"drifting"* ]]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
}

# --- the joint condition across targets ---

@test "one lagging target blocks the chunk that every other target passed" {
  # mock is flat from chunk 1; tier 28 only settles in chunk 2. Stopping at chunk
  # 1 would hand the measured phase a target that was still moving.
  chunk 1 0 "mock:200:0.50:1500" "28:200:10.0:1000" "28:200:20.0:500"
  chunk 2 3000 "mock:200:0.50:1500" "28:200:20.0:1500"
  run converge_warmup "warmup_scan_rep1" "WARMUP_TARGETS=mock 28" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 2 chunk(s)"* ]]
  [ "$(k6_call_count)" = "2" ]
}

@test "an expected target with no data blocks convergence" {
  # Every target that produced points is flat, but mock produced none: judging
  # only the targets present would pass a warm-up that never reached mock.
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" "WARMUP_TARGETS=28 mock" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier=mock"*"no requests"* ]]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
}

@test "without WARMUP_TARGETS the gate expects warm-up.js's full default set" {
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  for tier in mock calibration 5 10 20 28; do
    [[ "$output" == *"tier=${tier} "* ]]
  done
  [[ "$output" == *"did not converge"* ]]
}

# --- what the gate refuses to read ---

@test "non-200 points are excluded from the tail comparison" {
  # The 200 series is flat throughout; the failed requests in the middle would
  # dominate the penultimate window and read as drift if they were counted.
  chunk 1 0 "28:200:10.0:1000" "28:0:900.0:250" "28:200:10.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 1 chunk(s)"* ]]
}

@test "a target whose every request failed never converges" {
  chunk 1 0 "28:503:900.0:2000"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no HTTP 200 responses"* ]]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
}

@test "a target short of three windows does not converge" {
  # One point below 3 * WARMUP_WINDOW: there is no penultimate window to compare
  # against, so "no drift measured" must not be read as "no drift".
  chunk 1 0 "28:200:10.0:1499"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"fewer than three windows"* ]]
  [[ "$output" == *"did not converge within 4 chunk(s)"* ]]
  [ "$(k6_call_count)" = "4" ]
}

@test "the verdict after the last chunk is the one reported" {
  # Flat throughout, but only the fourth chunk brings the target to three windows:
  # that is the state the measured phase starts from.
  chunk 1 0    "28:200:10.0:400"
  chunk 2 400  "28:200:10.0:400"
  chunk 3 800  "28:200:10.0:400"
  chunk 4 1200 "28:200:10.0:600"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"converged after 4 chunk(s)"* ]]
  [ "$(k6_call_count)" = "4" ]
}

# --- the result the gate leaves behind ---

@test "chunks are filtered and merged into one gzipped file for the target" {
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  chunk 2 3000 "28:200:20.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [ ! -e "${RAW_RESULTS_DIR}/warmup_scan_rep1_combined.json" ]
  [ -e "${RESULTS_DIR}/warmup_scan_rep1.json.gz" ]
  [ "$(gunzip -c "${RESULTS_DIR}/warmup_scan_rep1.json.gz" | grep -c .)" = "3000" ]
  # The chunked path gzips the already-filtered file directly; finalize_result
  # is only used by the WARMUP_ITERATIONS_PER_TARGET bypass.
  [ ! -s "$FINALIZE_LOG" ]
}

@test "a metric outside KEEP_METRICS is filtered out of the gzipped file" {
  chunk 1 0 "28:200:10.0:1500"
  echo '{"metric":"vus","type":"Point","data":{"time":"2026-01-01T00:00:00.000000Z","value":5,"tags":{"tier":"28"}}}' \
    >> "${FIXTURE_DIR}/chunk1.json"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  run gunzip -c "${RESULTS_DIR}/warmup_scan_rep1.json.gz"
  [[ "$output" != *'"metric":"vus"'* ]]
}

@test "check_thermal_safety runs after every chunk and once more before the gzip" {
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  chunk 2 3000 "28:200:20.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [ "$(cat "$THERMAL_LOG")" = "$(printf '%s\n' 'warmup_scan_rep1 chunk1' 'warmup_scan_rep1 chunk2' 'warmup_scan_rep1 pre-finalize')" ]
}

# --- the fixed-iteration escape hatch ---

@test "WARMUP_ITERATIONS_PER_TARGET bypasses the gate for a single fixed pass" {
  # What keeps the smoke test and every fault-injection case fast: one pass, no
  # chunking, no convergence check at all.
  chunk 1 0 "28:200:10.0:1000" "28:200:20.0:500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 WARMUP_ITERATIONS_PER_TARGET=50 REP=1
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
  k6 inspect "$@" "${LOAD_TESTING_DIR}/warm-up.js" \
    | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["scenarios"]["warm_28"]))'
}

@test "warm-up.js defaults to constant-vus cut at the chunk duration with no drain" {
  # gracefulStop '0s' keeps the chunk's tail at full concurrency: a staggered
  # per-VU drain thins the load, and the thinner load reads as faster, settled
  # latency when it is only fewer VUs contending.
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
  chunk 1 0 "28:200:10.0:1500"
  run converge_warmup "warmup_scan_rep1" WARMUP_TARGETS=28 WARMUP_VUS=5 REP=1
  [ "$status" -eq 0 ]
  [[ "$(cat "$K6_LOG")" == *"WARMUP_DURATION_S=15"* ]]
  [[ "$(cat "$K6_LOG")" != *"WARMUP_ITERATIONS_PER_TARGET"* ]]

  : > "$K6_LOG"
  K6_CHUNK=0
  run converge_warmup "warmup_scan_rep2" WARMUP_TARGETS=28 WARMUP_VUS=5 WARMUP_ITERATIONS_PER_TARGET=50 REP=2
  [ "$status" -eq 0 ]
  [[ "$(cat "$K6_LOG")" != *"WARMUP_DURATION_S"* ]]
}
