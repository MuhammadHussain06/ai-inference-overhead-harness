#!/usr/bin/env bats
# Unit tests for run-all.sh, run-openloop.sh, run-predict-composition.sh and the harness
# scripts' per-cell wiring: the checks that must reject bad input or an unprepared host
# before any container starts, and the wiring that every measured cell runs under the
# samplers and power-state checks.

setup_file() {
  export LT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "run-all.sh: an unknown START_AT is rejected before any step or log directory" {
  before=$(ls "$LT_DIR/../results/logs" 2>/dev/null | wc -l)
  run env START_AT=nope "$LT_DIR/run-all.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"START_AT must be one of: suite openloop composition ablation analysis"* ]]
  [ "$(ls "$LT_DIR/../results/logs" 2>/dev/null | wc -l)" -eq "$before" ]
}

@test "run-all.sh: composition runs after openloop and before ablation" {
  grep -qx 'STEPS=(suite openloop composition ablation analysis)' "$LT_DIR/run-all.sh"
  openloop=$(grep -n '^if runs openloop' "$LT_DIR/run-all.sh" | cut -d: -f1)
  composition=$(grep -n '^if runs composition' "$LT_DIR/run-all.sh" | cut -d: -f1)
  ablation=$(grep -n '^if runs ablation' "$LT_DIR/run-all.sh" | cut -d: -f1)
  [ -n "$composition" ] && [ "$openloop" -lt "$composition" ] && [ "$composition" -lt "$ablation" ]
  body=$(sed -n '/^if runs composition/,/^fi$/p' "$LT_DIR/run-all.sh")
  [[ "$body" == *'./run-predict-composition.sh "$(latest_run suite)"'* ]]
  [[ "$body" == *"FAILED (see composition.log); continuing"* ]]
  [[ "$body" != *"exit"* ]]
}

@test "run-all.sh: START_AT=composition is accepted and skips only the steps before it" {
  parse=$(sed -n '/^STEPS=/,/^fi$/p' "$LT_DIR/run-all.sh")
  runs_fn=$(sed -n '/^runs() {/,/^}/p' "$LT_DIR/run-all.sh")
  run env START_AT=composition bash -c "${parse}
${runs_fn}
for s in suite openloop composition ablation analysis; do runs \$s && echo \"run \$s\"; done"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'run composition\nrun ablation\nrun analysis')" ]
}

@test "run-predict-composition.sh: a missing or non-suite run directory is rejected" {
  run "$LT_DIR/run-predict-composition.sh" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a run-suite.sh run directory"* ]]
  run "$LT_DIR/run-predict-composition.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a run-suite.sh run directory"* ]]
}

@test "run-predict-composition.sh: a suite run without a Python cpuset or power state is refused" {
  echo '{}' > "$BATS_TEST_TMPDIR/run_metadata.json"
  run "$LT_DIR/run-predict-composition.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded no Python cpuset"* ]]
  echo '{"cores_used_by_suite": {"python_service_cpuset": "0-1", "python_service_cpus_quota": "2.0"}}' \
    > "$BATS_TEST_TMPDIR/run_metadata.json"
  run "$LT_DIR/run-predict-composition.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded no CPU power state"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/predict_composition.json" ]
}

@test "run-predict-composition.sh: a non-integer call count is rejected" {
  run env COMPOSITION_N=lots "$LT_DIR/run-predict-composition.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COMPOSITION_N='lots' is not a positive integer"* ]]
}

@test "run-predict-composition.sh: the one-off container is pinned to the suite's Python cpuset" {
  grep -q 'PYTHON_CPUSET="$PY_CPUSET" PYTHON_CPUS="$PY_CPUS"' "$LT_DIR/run-predict-composition.sh"
  grep -q 'compose run --rm --no-deps -T' "$LT_DIR/run-predict-composition.sh"
  grep -q -- '--expect-cpuset "$PY_CPUSET"' "$LT_DIR/run-predict-composition.sh"
  grep -qx 'exec < /dev/null' "$LT_DIR/run-predict-composition.sh"
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
  body=$(sed -n '/^run_cell() {/,/^}/p' "$LT_DIR/lib/suite-stack.sh")
  [[ "$body" == *'start_placement_sampler "$cell"'* ]]
  [ "$(grep -c 'stop_placement_sampler' <<< "$body")" -eq 2 ]
  [ "$(grep -c 'check_power_state' <<< "$body")" -eq 2 ]
  [[ "$body" == *'start_freq_sampler "$cell" "$SERVICE_CPUSETS" "$PINNED_CPUS"'* ]]
  [ "$(grep -c 'stop_freq_sampler' <<< "$body")" -eq 2 ]
  grep -q '^PLACEMENT_LOG="${RESULTS_DIR}/connection_placement_log.txt"' "$LT_DIR/run-suite.sh"
  grep -q -- '--avoid-cpus "$PINNED_CPUS"' "$LT_DIR/lib/suite-stack.sh"
}

@test "run-smoke-test.sh: its overload cell goes through run-openloop.sh" {
  grep -q 'OPENLOOP_PHASE=smoke-openloop ./run-openloop.sh "$SUITE_DIR"' "$LT_DIR/run-smoke-test.sh"
}

@test "install-test-deps.sh: a venv without a usable bin/python or bin/pip is rebuilt, a usable one reused" {
  fn=$(awk '/^build_venv\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$LT_DIR/../install-test-deps.sh")
  # Stands in for python3: `-m venv [--clear] DIR` lays down executable bin/python and bin/pip.
  cat > "$BATS_TEST_TMPDIR/fakepy" <<'PY'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Python 3.x"; exit 0; }
dir="${@: -1}"
echo "venv $*" >> "$(dirname "$0")/venv.log"
mkdir -p "$dir/bin"
printf '#!/bin/sh\nexit 0\n' > "$dir/bin/python"; printf '#!/bin/sh\nexit 0\n' > "$dir/bin/pip"
chmod +x "$dir/bin/python" "$dir/bin/pip"
PY
  chmod +x "$BATS_TEST_TMPDIR/fakepy"
  mkdir -p "$BATS_TEST_TMPDIR/v/Scripts"
  run bash -c "${fn}
cd '$BATS_TEST_TMPDIR'; build_venv v ./fakepy; build_venv v ./fakepy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recreated v: it had no usable bin/python or bin/pip"* ]]
  [[ "$output" == *"reusing v"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/venv.log")" = "venv -m venv --clear v" ]
}
