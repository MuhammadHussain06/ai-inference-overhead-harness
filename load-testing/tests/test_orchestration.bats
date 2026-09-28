#!/usr/bin/env bats
# Unit tests for run-all.sh, run-openloop.sh and the harness scripts' per-cell wiring: the
# checks that must reject bad input or an unprepared host before any container starts,
# and the wiring that every measured cell runs under the samplers and power-state checks.

setup_file() {
  export LT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "run-all.sh: an unknown START_AT is rejected before any step or log directory" {
  before=$(ls "$LT_DIR/../results/logs" 2>/dev/null | wc -l)
  run env START_AT=nope "$LT_DIR/run-all.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"START_AT must be one of: suite openloop ablation analysis"* ]]
  [ "$(ls "$LT_DIR/../results/logs" 2>/dev/null | wc -l)" -eq "$before" ]
}

@test "run-openloop.sh: a directory that is not a suite run is rejected" {
  run "$LT_DIR/run-openloop.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a run-suite.sh run directory"* ]]
}

@test "run-openloop.sh: a non-integer rate is rejected before the stack is touched" {
  echo '{}' > "$BATS_TEST_TMPDIR/run_metadata.json"
  run env OPENLOOP_RATES="800 fast" "$LT_DIR/run-openloop.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Open-loop rate 'fast' is not a positive integer"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/openloop_log.txt" ]
}

@test "run-openloop.sh: a run with no scan cell for the target is rejected" {
  echo '{}' > "$BATS_TEST_TMPDIR/run_metadata.json"
  run "$LT_DIR/run-openloop.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not derive the plateau throughput of target 28"* ]]
}

@test "run-openloop.sh: a suite run that recorded no power state is refused" {
  echo '{}' > "$BATS_TEST_TMPDIR/run_metadata.json"
  run env OPENLOOP_RATES=100 "$LT_DIR/run-openloop.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded no CPU power state"* ]]
}

@test "run-suite.sh and run-ablation.sh: the power state is checked before the run directory exists" {
  for script in run-suite.sh run-ablation.sh; do
    check=$(grep -n '^require_prepared_host' "$LT_DIR/$script" | cut -d: -f1)
    layout=$(grep -n '^prepare_run_dir' "$LT_DIR/$script" | cut -d: -f1)
    [ -n "$check" ] && [ "$check" -lt "$layout" ]
    grep -q '"power_state": $(power_state_json "$REQUIRED_TURBO" "$POWER_STATE_AT_START")' "$LT_DIR/$script"
  done
}

@test "run-all.sh: the power state is checked before the first step" {
  check=$(grep -n 'require_prepared_host' "$LT_DIR/run-all.sh" | cut -d: -f1)
  first_step=$(grep -n '^if runs suite' "$LT_DIR/run-all.sh" | cut -d: -f1)
  [ -n "$check" ] && [ "$check" -lt "$first_step" ]
}

@test "run-ablation.sh: every measured cell runs between power checks under the clock sampler" {
  body=$(sed -n '/cell_name="ablation_/,/check_oom_killed/p' "$LT_DIR/run-ablation.sh")
  [ "$(grep -c 'check_power_state' <<< "$body")" -eq 2 ]
  [ "$(grep -c 'start_freq_sampler' <<< "$body")" -eq 1 ]
  [ "$(grep -c 'stop_freq_sampler' <<< "$body")" -eq 2 ]
}

@test "run-suite.sh: every measured cell runs between power checks under both samplers, stopped on both exits" {
  body=$(sed -n '/^run_cell() {/,/^}/p' "$LT_DIR/run-suite.sh")
  [[ "$body" == *'start_placement_sampler "$cell"'* ]]
  [ "$(grep -c 'stop_placement_sampler' <<< "$body")" -eq 2 ]
  [ "$(grep -c 'check_power_state' <<< "$body")" -eq 2 ]
  [[ "$body" == *'start_freq_sampler "$cell" "$SERVICE_CPUSETS" "$PINNED_CPUS"'* ]]
  [ "$(grep -c 'stop_freq_sampler' <<< "$body")" -eq 2 ]
  grep -q '^PLACEMENT_LOG="${RESULTS_DIR}/connection_placement_log.txt"' "$LT_DIR/run-suite.sh"
  grep -q -- '--avoid-cpus "$PINNED_CPUS"' "$LT_DIR/run-suite.sh"
}

@test "run-smoke-test.sh: its overload cell goes through run-openloop.sh" {
  grep -q 'OPENLOOP_PHASE=smoke-openloop ./run-openloop.sh "$SUITE_DIR"' "$LT_DIR/run-smoke-test.sh"
}
