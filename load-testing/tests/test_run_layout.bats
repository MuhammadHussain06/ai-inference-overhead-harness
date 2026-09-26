#!/usr/bin/env bats
# Unit tests for lib/run-layout.sh (run directories, archiving, measurement fingerprint)
# and virtualization_state() in lib/host-provenance.sh.

setup_file() {
  export LT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export LAYOUT="${LT_DIR}/lib/run-layout.sh"
  export PROVENANCE="${LT_DIR}/lib/host-provenance.sh"
}

setup() {
  # shellcheck source=../lib/run-layout.sh
  . "$LAYOUT"
  ROOT="${BATS_TEST_TMPDIR}/results"
  mkdir -p "$ROOT"
}

@test "run_host_label: lowercases and replaces characters outside [a-z0-9.-]" {
  uname() { echo "My_Host Name!"; }
  run run_host_label
  [ "$output" = "my-host-name" ]
}

@test "run_host_label: falls back to unknown-host when uname gives nothing usable" {
  uname() { echo "___"; }
  run run_host_label
  [ "$output" = "unknown-host" ]
}

@test "run_timestamp: compact UTC form" {
  run run_timestamp
  [[ "$output" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

@test "archive_superseded_runs: moves only the same kind and host, suffixing a taken name" {
  mkdir -p "$ROOT/suite_h1_20260101T000000Z" "$ROOT/suite_h2_20260101T000000Z" \
           "$ROOT/ablation_h1_20260101T000000Z" "$ROOT/suite_h1-b_20260101T000000Z" \
           "$ROOT/archive/suite_h1_20260101T000000Z"
  run archive_superseded_runs "$ROOT" suite h1 aaaaaaaaaaaa
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/suite_h1_20260101T000000Z" ]
  [ -d "$ROOT/archive/suite_h1_20260101T000000Z.1" ]
  [ -d "$ROOT/suite_h2_20260101T000000Z" ]
  [ -d "$ROOT/suite_h1-b_20260101T000000Z" ]
  [ -d "$ROOT/ablation_h1_20260101T000000Z" ]
}

@test "archive_superseded_runs: leaves a run recorded on another machine with the same hostname" {
  mkdir -p "$ROOT/suite_h1_20260101T000000Z" "$ROOT/suite_h1_20260102T000000Z"
  printf '{\n  "machine_id_hash": "bbbbbbbbbbbb",\n  "x": 1\n}\n' > "$ROOT/suite_h1_20260101T000000Z/run_metadata.json"
  printf '{\n  "machine_id_hash": "aaaaaaaaaaaa"\n}\n' > "$ROOT/suite_h1_20260102T000000Z/run_metadata.json"
  run archive_superseded_runs "$ROOT" suite h1 aaaaaaaaaaaa
  [ "$status" -eq 0 ]
  [ -d "$ROOT/suite_h1_20260101T000000Z" ]
  [ -d "$ROOT/archive/suite_h1_20260102T000000Z" ]
}

@test "machine_id_hash: 12 hex digits, or unknown without a machine ID" {
  run machine_id_hash
  [[ "$output" =~ ^([0-9a-f]{12}|unknown)$ ]]
}

@test "archive_flat_layout: suite takes top-level suite files and gc-logs, leaves ablation and probe files and run dirs" {
  touch "$ROOT/baseline_28_rep1.json.gz" "$ROOT/run_metadata.json" "$ROOT/calibration_log.txt" "$ROOT/probe_x_short.json" \
        "$ROOT/calib_28_vus16.json.gz" "$ROOT/calib_5_vus16.json" \
        "$ROOT/ablation_cpuset_0-1_rep1.json.gz" "$ROOT/.gitkeep"
  mkdir -p "$ROOT/gc-logs" "$ROOT/suite_h1_20260101T000000Z"
  touch "$ROOT/gc-logs/gc_baseline_rep1.log"
  run archive_flat_layout "$ROOT" suite
  [ "$status" -eq 0 ]
  dest=$(find "$ROOT/archive" -mindepth 1 -maxdepth 1 -type d)
  [ -f "$dest/baseline_28_rep1.json.gz" ]
  [ -f "$dest/run_metadata.json" ]
  [ -f "$dest/calibration_log.txt" ]
  [ -f "$dest/calib_28_vus16.json.gz" ]
  [ -f "$ROOT/calib_5_vus16.json" ]
  [ -f "$dest/gc-logs/gc_baseline_rep1.log" ]
  [ -f "$ROOT/ablation_cpuset_0-1_rep1.json.gz" ]
  [ -f "$ROOT/probe_x_short.json" ]
  [ -f "$ROOT/.gitkeep" ]
  [ -d "$ROOT/suite_h1_20260101T000000Z" ]
}

@test "archive_flat_layout: ablation takes only ablation_ files, into a _ablation directory" {
  touch "$ROOT/ablation_cpuset_0-1_rep1.json.gz" "$ROOT/ablation_run_metadata.json" "$ROOT/baseline_28_rep1.json.gz"
  run archive_flat_layout "$ROOT" ablation
  [ "$status" -eq 0 ]
  dest=$(find "$ROOT/archive" -mindepth 1 -maxdepth 1 -type d -name '*_ablation')
  [ -f "$dest/ablation_cpuset_0-1_rep1.json.gz" ]
  [ -f "$dest/ablation_run_metadata.json" ]
  [ -f "$ROOT/baseline_28_rep1.json.gz" ]
}

@test "archive_flat_layout: no flat files, no archive directory" {
  mkdir -p "$ROOT/suite_h1_20260101T000000Z"
  run archive_flat_layout "$ROOT" suite
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/archive" ]
}

@test "archive_flat_layout: succeeds under set -e for both kinds" {
  touch "$ROOT/baseline_28_rep1.json.gz" "$ROOT/ablation_x_rep1.json.gz"
  run bash -ec ". '$LAYOUT'; archive_flat_layout '$ROOT' suite; archive_flat_layout '$ROOT' ablation; echo done"
  [ "$status" -eq 0 ]
  [[ "$output" == *done ]]
}

@test "prepare_run_dir: names a new run directory and archives this host's previous run" {
  uname() { echo "HostA"; }
  mkdir -p "$ROOT/suite_hosta_20260101T000000Z" "$ROOT/suite_hostb_20260101T000000Z"
  prepare_run_dir "$ROOT" suite
  [[ "$RUN_ID" =~ ^suite_hosta_[0-9]{8}T[0-9]{6}Z$ ]]
  [ "$RESULTS_DIR" = "$ROOT/$RUN_ID" ]
  [ -d "$ROOT/archive/suite_hosta_20260101T000000Z" ]
  [ -d "$ROOT/suite_hostb_20260101T000000Z" ]
}

@test "prepare_run_dir: succeeds under set -euo pipefail with earlier runs of this host present" {
  host=$(run_host_label)
  mkdir -p "$ROOT/suite_${host}_20260101T000000Z" "$ROOT/suite_${host}_20260102T000000Z"
  echo '{"machine_id_hash": "unknown"}' > "$ROOT/suite_${host}_20260101T000000Z/run_metadata.json"
  run bash -euo pipefail -c ". '$LAYOUT'; prepare_run_dir '$ROOT' suite; echo \"\$RUN_ID\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"suite_${host}_"* ]]
  [ -d "$ROOT/archive/suite_${host}_20260101T000000Z" ]
  [ -d "$ROOT/archive/suite_${host}_20260102T000000Z" ]
}

@test "prepare_run_dir: RESULTS_DIR_OVERRIDE names the run directory and archives nothing" {
  mkdir -p "$ROOT/suite_$(run_host_label)_20260101T000000Z"
  touch "$ROOT/baseline_28_rep1.json.gz"
  RESULTS_DIR_OVERRIDE="${BATS_TEST_TMPDIR}/case1" prepare_run_dir "$ROOT" suite
  [ "$RESULTS_DIR" = "${BATS_TEST_TMPDIR}/case1" ]
  [ "$RUN_ID" = "case1" ]
  [ ! -e "$ROOT/archive" ]
  [ -f "$ROOT/baseline_28_rep1.json.gz" ]
}

@test "measurement_fingerprint: tracks measured files, ignores tests, docs and commit state" {
  repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$repo/services/fraud-ml-service/app" "$repo/services/fraud-ml-service/tests" \
           "$repo/load-testing/tests" "$repo/load-testing/lib"
  echo "a" > "$repo/services/fraud-ml-service/app/main.py"
  echo "t" > "$repo/services/fraud-ml-service/tests/test_x.py"
  echo "b" > "$repo/load-testing/tests/x.bats"
  echo "c" > "$repo/load-testing/lib/gate.sh"
  echo "d" > "$repo/docker-compose.yml"
  echo "r" > "$repo/README.md"
  git -C "$repo" init -q
  git -C "$repo" add -A
  fp1=$(measurement_fingerprint "$repo")
  [[ "$fp1" =~ ^[0-9a-f]{64}$ ]]

  echo "r2" > "$repo/README.md"
  echo "t2" > "$repo/services/fraud-ml-service/tests/test_x.py"
  echo "b2" > "$repo/load-testing/tests/x.bats"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm x
  [ "$(measurement_fingerprint "$repo")" = "$fp1" ]

  echo "a2" > "$repo/services/fraud-ml-service/app/main.py"
  [ "$(measurement_fingerprint "$repo")" != "$fp1" ]
}

@test "measurement_fingerprint: outside a git checkout" {
  run measurement_fingerprint "$BATS_TEST_TMPDIR"
  [ "$output" = "unknown (not a git checkout)" ]
}

@test "virtualization_state: reports systemd-detect-virt, including 'none' on its non-zero exit" {
  stub="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho amazon\n' > "$stub/systemd-detect-virt"
  chmod +x "$stub/systemd-detect-virt"
  run env PATH="$stub:$PATH" bash -c ". '$PROVENANCE'; virtualization_state"
  [ "$output" = "amazon" ]

  printf '#!/bin/sh\necho none\nexit 1\n' > "$stub/systemd-detect-virt"
  run env PATH="$stub:$PATH" bash -c ". '$PROVENANCE'; virtualization_state"
  [ "$output" = "none" ]
}

@test "virtualization_state: unknown without systemd-detect-virt" {
  run bash -c "PATH=/nonexistent; . '$PROVENANCE'; virtualization_state"
  [ "$output" = "unknown" ]
}

@test "host_provenance_json: valid JSON carrying virtualization" {
  run bash -c ". '$PROVENANCE'; host_provenance_json | python3 -c 'import json,sys; print(\"virtualization\" in json.load(sys.stdin))'"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

@test "harness scripts: both create their run directory through prepare_run_dir and export it to compose" {
  for script in run-suite.sh run-ablation.sh; do
    grep -q '^\. lib/run-layout\.sh' "$LT_DIR/$script"
    grep -q '^prepare_run_dir \.\./results ' "$LT_DIR/$script"
    grep -q '^export RUN_RESULTS_DIR' "$LT_DIR/$script"
    grep -q '"machine_id_hash": "\$(machine_id_hash)"' "$LT_DIR/$script"
  done
  [ "$(grep -c '\${RUN_RESULTS_DIR:-\./results}' "$LT_DIR/../docker-compose.yml")" -eq 2 ]
}
