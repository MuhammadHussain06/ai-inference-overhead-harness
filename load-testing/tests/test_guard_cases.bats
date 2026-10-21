#!/usr/bin/env bats
# Unit tests for the open-loop and composition fault injection: the case files are
# well-formed and name refusals and guard tags the scripts actually emit, their metadata
# patches apply to a suite run's metadata, and fault-injection/lib/guard-cases.sh scores a
# case from the script's exit status, its failures log and its console output. The verdict
# tests run the case runner against a stub harness script in a scratch tree, with docker
# stubbed, so no stack is started.

setup_file() {
  export REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export FI_DIR="${REPO}/fault-injection"
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
  FIXTURE="${WORKDIR}/fixture"
  mkdir -p "$FIXTURE" "${WORKDIR}/bin"
  # The fields run-openloop.sh and run-predict-composition.sh read from a suite run.
  cat > "${FIXTURE}/run_metadata.json" <<'EOF'
{"power_state": {"turbo_required": "off", "snapshot": "power_source=ac turbo=off"},
 "jvm_pinned_options": "-Xms1536m -XX:+UseG1GC",
 "cores_used_by_suite": {"python_service_cpuset": "0-1,4-5", "transaction_service_cpuset": "2-3",
                         "k6_cpuset": "6-7", "python_service_cpus_quota": "4",
                         "transaction_service_cpus_quota": "2", "k6_cpus_quota": "2"},
 "suite_config": {"uvicorn_workers": "3", "thread_limiter_tokens": 40, "max_vus": 1, "cooldown_s": 10}}
EOF
  echo "scan cell" > "${FIXTURE}/scan_calibration_vus1_rep1.json.gz"

  DOCKER_LOG="${WORKDIR}/docker.log"
  : > "$DOCKER_LOG"
  cat > "${WORKDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $* | RUN_RESULTS_DIR=${RUN_RESULTS_DIR:-}" >> "$DOCKER_LOG"
EOF
  chmod +x "${WORKDIR}/bin/docker"
  export PATH="${WORKDIR}/bin:${PATH}" DOCKER_LOG FIXTURE
}

# A scratch repo layout: the real case runner and topology helpers, a stub harness script
# whose behavior the case's ENV selects, and the cases the test writes.
make_stub_tree() {
  TREE="${WORKDIR}/tree"
  mkdir -p "${TREE}/fault-injection/lib" "${TREE}/fault-injection/cases/stub" "${TREE}/load-testing/lib"
  cp "${FI_DIR}/lib/guard-cases.sh" "${TREE}/fault-injection/lib/"
  cp "${REPO}/load-testing/lib/topology.sh" "${TREE}/load-testing/lib/"
  cat > "${TREE}/load-testing/stub.sh" <<'EOF'
#!/usr/bin/env bash
run_dir="$1"
echo "metadata: $(cat "${run_dir}/run_metadata.json" | tr -d '\n')"
case "${STUB_MODE:-clean}" in
  clean)   echo "out" > "${run_dir}/stub_output.txt"; exit 0 ;;
  guard)   echo "rep=1 [FATAL] [recorded-settings]: differs" >> "${run_dir}/stub_failures_log.txt"; exit 1 ;;
  other)   echo "rep=1 [FATAL] [smt]: overlap" >> "${run_dir}/stub_failures_log.txt"; exit 1 ;;
  refuse)  echo "[!] ${run_dir} recorded no Python CPU quota." >&2; exit 1 ;;
  empty)   exit 0 ;;
  dirty)   echo "rep=1 [FATAL] [uncaught] stray" >> "${run_dir}/stub_failures_log.txt"; exit 0 ;;
esac
EOF
  chmod +x "${TREE}/load-testing/stub.sh"
}

write_case() {
  printf '%s\n' "${@:2}" > "${TREE}/fault-injection/cases/stub/${1}.case"
}

run_stub_cases() {
  run bash -c '
    . "$1/fault-injection/lib/guard-cases.sh"
    CHECK_NAME=stub SCRIPT=stub.sh FAILURES_FILE=stub_failures_log.txt DEFAULT_ENV=""
    control_check() { [ -s stub_output.txt ]; }
    host_has_smt() { [ "${STUB_SMT:-no}" = yes ]; }
    run_guard_cases "$2"
  ' _ "$TREE" "$FIXTURE"
  REPORT="${TREE}/fault-injection/results/guard_verification_stub.csv"
}

verdict_of() {
  awk -F, -v c="$1" '$1 == c { print $NF }' "$REPORT"
}

case_field() {
  bash -c '
    FAULT_SMT_JAVA=2 FAULT_SMT_PYTHON=3 FAULT_SMT_JAVA_CPUS=1 FAULT_SMT_PYTHON_CPUS=1
    DESCRIPTION="" EXPECT_GUARD="" EXPECT_REFUSAL="" PATCH_METADATA="" SETUP="" REQUIRES="" ENV=""
    . "$1"; printf "%s" "${!2}"' _ "$1" "$2"
}

script_of() {
  case "$(basename "$(dirname "$1")")" in
    openloop) echo "${REPO}/load-testing/run-openloop.sh" ;;
    composition) echo "${REPO}/load-testing/run-predict-composition.sh" ;;
  esac
}

@test "each check has one unmodified control, and every case sets a description and at most one expectation" {
  for dir in openloop composition; do
    controls=0
    for f in "${FI_DIR}/cases/${dir}"/*.case; do
      [ -n "$(case_field "$f" DESCRIPTION)" ] || { echo "no DESCRIPTION: $f"; false; }
      guard=$(case_field "$f" EXPECT_GUARD)
      refusal=$(case_field "$f" EXPECT_REFUSAL)
      if [ -n "$guard" ] && [ -n "$refusal" ]; then echo "two expectations: $f"; false; fi
      if [ -z "$guard" ] && [ -z "$refusal" ]; then controls=$((controls + 1)); fi
    done
    [ "$controls" -eq 1 ] || { echo "${dir}: ${controls} controls"; false; }
    [ -f "${FI_DIR}/cases/${dir}/00-unmodified.case" ]
  done
}

@test "every expected refusal is text its script prints, and every expected guard a tag its abort path logs" {
  for f in "${FI_DIR}"/cases/openloop/*.case "${FI_DIR}"/cases/composition/*.case; do
    script=$(script_of "$f")
    refusal=$(case_field "$f" EXPECT_REFUSAL)
    guard=$(case_field "$f" EXPECT_GUARD)
    if [ -n "$refusal" ]; then
      # Fixed text before the first variable the script interpolates.
      grep -qF "$refusal" "$script" \
        || grep -qF "${refusal#recorded no }" "$script" \
        || { echo "refusal not in $(basename "$script"): ${refusal} ($f)"; false; }
    fi
    if [ -n "$guard" ]; then
      cat "$script" "${REPO}"/load-testing/lib/*.sh | grep -qF "\"${guard}" \
        || { echo "guard ${guard} never logged by $(basename "$script") or its libraries ($f)"; false; }
    fi
  done
}

@test "every case's metadata patch applies to a suite run's metadata and changes it" {
  . "${FI_DIR}/lib/guard-cases.sh"
  for f in "${FI_DIR}"/cases/openloop/*.case "${FI_DIR}"/cases/composition/*.case; do
    ops=$(case_field "$f" PATCH_METADATA)
    [ -n "$ops" ] || continue
    cp "${FIXTURE}/run_metadata.json" "${WORKDIR}/patched.json"
    patch_metadata "${WORKDIR}/patched.json" "$ops" || { echo "patch failed: $f"; false; }
    ! cmp -s "${FIXTURE}/run_metadata.json" "${WORKDIR}/patched.json" || { echo "patch changed nothing: $f"; false; }
  done
}

@test "patch_metadata sets, deletes and appends by dotted path" {
  . "${FI_DIR}/lib/guard-cases.sh"
  cp "${FIXTURE}/run_metadata.json" "${WORKDIR}/m.json"
  patch_metadata "${WORKDIR}/m.json" "set cores_used_by_suite.python_service_cpus_quota 64
del suite_config.thread_limiter_tokens
append power_state.snapshot fault=injected"
  run python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["cores_used_by_suite"]["python_service_cpus_quota"], "thread_limiter_tokens" in m["suite_config"], m["power_state"]["snapshot"])
' "${WORKDIR}/m.json"
  [ "$output" = "64 False power_source=ac turbo=off fault=injected" ]
}

@test "patch_metadata fails on an unknown operation or a missing path" {
  . "${FI_DIR}/lib/guard-cases.sh"
  cp "${FIXTURE}/run_metadata.json" "${WORKDIR}/m.json"
  run patch_metadata "${WORKDIR}/m.json" "rename suite_config.max_vus x"
  [ "$status" -ne 0 ]
  run patch_metadata "${WORKDIR}/m.json" "del suite_config.no_such_field"
  [ "$status" -ne 0 ]
}

@test "the control passes only when the script ran clean, its failures log is empty and the control check holds" {
  make_stub_tree
  write_case 00-unmodified 'DESCRIPTION="control"'
  write_case 01-dirty 'DESCRIPTION="clean exit, but a failures line"' 'ENV="STUB_MODE=dirty"'
  write_case 02-no-output 'DESCRIPTION="clean exit, no output"' 'ENV="STUB_MODE=empty"'
  run_stub_cases
  [ "$(verdict_of 00-unmodified)" = PASS ]
  [ "$(verdict_of 01-dirty)" = FAIL ]
  [ "$(verdict_of 02-no-output)" = FAIL ]
  [ "$status" -ne 0 ]
}

@test "a guard case passes on its tag in the failures log and fails on another tag or a completed run" {
  make_stub_tree
  write_case 01-right 'DESCRIPTION="fires"' 'EXPECT_GUARD="[recorded-settings]"' 'ENV="STUB_MODE=guard"'
  write_case 02-wrong 'DESCRIPTION="wrong guard"' 'EXPECT_GUARD="[recorded-settings]"' 'ENV="STUB_MODE=other"'
  write_case 03-silent 'DESCRIPTION="never fires"' 'EXPECT_GUARD="[recorded-settings]"' 'ENV="STUB_MODE=clean"'
  run_stub_cases
  [ "$(verdict_of 01-right)" = PASS ]
  [ "$(verdict_of 02-wrong)" = FAIL ]
  [ "$(verdict_of 03-silent)" = FAIL ]
  grep -q '^02-wrong,.*"aborted, but not via \[recorded-settings\]"' "$REPORT"
  grep -q '^03-silent,.*"run completed despite the fault"' "$REPORT"
}

@test "a refusal case passes on its text in the console and fails on an abort without it" {
  make_stub_tree
  write_case 01-refused 'DESCRIPTION="refused"' 'EXPECT_REFUSAL="recorded no Python CPU quota"' 'ENV="STUB_MODE=refuse"'
  write_case 02-other 'DESCRIPTION="other abort"' 'EXPECT_REFUSAL="recorded no Python CPU quota"' 'ENV="STUB_MODE=other"'
  run_stub_cases
  [ "$(verdict_of 01-refused)" = PASS ]
  [ "$(verdict_of 02-other)" = FAIL ]
}

@test "each case runs on its own patched copy of the fixture's metadata, and the fixture is left untouched" {
  make_stub_tree
  before=$(cat "${FIXTURE}/run_metadata.json")
  write_case 01-patched 'DESCRIPTION="patched"' 'EXPECT_GUARD="[recorded-settings]"' 'ENV="STUB_MODE=guard"' \
    'PATCH_METADATA="set suite_config.max_vus 99"'
  run_stub_cases
  [ "$(cat "${FIXTURE}/run_metadata.json")" = "$before" ]
  [ ! -e "${FIXTURE}/stub_failures_log.txt" ]
  grep -q '"max_vus": "99"' "${TREE}/fault-injection/scratch/stub/01-patched/results/run_metadata.json"
  [ ! -e "${TREE}/fault-injection/scratch/stub/01-patched/results/scan_calibration_vus1_rep1.json.gz" ]
}

@test "an SMT-only case is skipped, not passed, on a host without SMT" {
  make_stub_tree
  write_case 01-smt 'DESCRIPTION="smt"' 'EXPECT_GUARD="[smt]"' 'REQUIRES="smt"' 'ENV="STUB_MODE=other"'
  STUB_SMT=no run_stub_cases
  [ "$(verdict_of 01-smt)" = SKIP ]
  [ "$status" -eq 0 ]
}

@test "stack-up starts python-service on the case's copy before the run and every case stops the stack after" {
  make_stub_tree
  write_case 01-stack 'DESCRIPTION="stack up"' 'EXPECT_GUARD="[recorded-settings]"' 'SETUP="stack-up"' 'ENV="STUB_MODE=guard"'
  run_stub_cases
  copy="${TREE}/fault-injection/scratch/stub/01-stack/results"
  grep -q "compose -f .*docker-compose.yml up -d python-service | RUN_RESULTS_DIR=${copy}$" "$DOCKER_LOG"
  [ "$(grep -n ' up -d ' "$DOCKER_LOG" | cut -d: -f1)" -lt "$(grep -n ' down' "$DOCKER_LOG" | tail -1 | cut -d: -f1)" ]
  grep -q " down | RUN_RESULTS_DIR=${copy}$" "$DOCKER_LOG"
}

@test "without a fixture the runner stops before any case and names how to get one" {
  make_stub_tree
  write_case 00-unmodified 'DESCRIPTION="control"'
  FIXTURE="${WORKDIR}/missing" run_stub_cases
  [ "$status" -eq 2 ]
  [[ "$output" == *"Run ./verify-guards.sh"* ]]
  [ ! -d "${TREE}/fault-injection/scratch/stub" ]
}

@test "verify-guards.sh runs the open-loop and composition cases on case 00's run, only after case 00 passed" {
  hook=$(sed -n '/^CHECKS_FAILED=0/,/^fi/p' "${FI_DIR}/verify-guards.sh")
  [[ "$hook" == *"grep -q '^00-unmodified,.*,PASS\$' \"\$REPORT_CSV\""* ]]
  [[ "$hook" == *'./verify-guards-openloop.sh "${SCRATCH}/00-unmodified/results"'* ]]
  [[ "$hook" == *'./verify-guards-composition.sh "${SCRATCH}/00-unmodified/results"'* ]]
  [[ "$hook" == *"CHECKS_FAILED=2"* ]]
  tail -1 "${FI_DIR}/verify-guards.sh" | grep -qF '[ "$FAILED" -eq 0 ] && [ "$CHECKS_FAILED" -eq 0 ]'
}

@test "the runners are executable and cover every case directory" {
  [ -x "${FI_DIR}/verify-guards-openloop.sh" ]
  [ -x "${FI_DIR}/verify-guards-composition.sh" ]
  grep -q '^CHECK_NAME="openloop"$' "${FI_DIR}/verify-guards-openloop.sh"
  grep -q '^CHECK_NAME="composition"$' "${FI_DIR}/verify-guards-composition.sh"
  [ "$(find "${FI_DIR}/cases" -mindepth 1 -maxdepth 1 -type d | sort | xargs -n1 basename | tr '\n' ' ')" = "composition openloop " ]
}
