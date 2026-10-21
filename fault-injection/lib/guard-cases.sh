# Shared by verify-guards-openloop.sh and verify-guards-composition.sh: each case runs one
# harness script against its own run directory holding a copy of a finished suite run's
# run_metadata.json (the fixture), patched to carry the fault, and records whether the
# expected guard rejected it.
#
# The caller sets CHECK_NAME (openloop or composition), SCRIPT (the harness script, relative
# to load-testing/), FAILURES_FILE (that script's failures log), DEFAULT_ENV (VAR=VALUE
# list every case runs with) and defines control_check() (extra checks for the control
# case, run in the case directory, returning non-zero on failure), then calls
# run_guard_cases.
#
# Case files (cases/<CHECK_NAME>/*.case) are sourced and set:
#   DESCRIPTION     what is misconfigured
#   EXPECT_GUARD    tag the abort must log in FAILURES_FILE, e.g. "[recorded-settings]"
#   EXPECT_REFUSAL  text the console output must contain, for a check that refuses before
#                   the script opens its failures log; empty for both means the control case
#   PATCH_METADATA  one operation per line on the fixture copy's run_metadata.json:
#                   "set <dotted.path> <value>", "del <dotted.path>" or
#                   "append <dotted.path> <text>" (after a space)
#   SETUP           "stack-up" starts the measured python-service before the case runs
#   REQUIRES        "smt" skips the case on a host without SMT
#   ENV             VAR=VALUE list applied after DEFAULT_ENV

GUARD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "${GUARD_ROOT}/.." && pwd)
CASE_TIMEOUT="${CASE_TIMEOUT_S:-600}"

# The suite run every case copies: an explicit directory, else the run verify-guards.sh's
# unmodified case leaves behind.
resolve_fixture() {
  local fixture="${1:-${GUARD_FIXTURE_RUN_DIR:-${GUARD_ROOT}/scratch/00-unmodified/results}}"
  if [ ! -f "${fixture}/run_metadata.json" ]; then
    echo "[!] No suite run to copy at ${fixture}. Run ./verify-guards.sh (its unmodified case" >&2
    echo "    leaves one), or pass a run-suite.sh run directory as the first argument." >&2
    exit 2
  fi
  (cd "$fixture" && pwd)
}

host_has_smt() {
  local siblings="/sys/devices/system/cpu/cpu0/topology/thread_siblings_list"
  [ -r "$siblings" ] || return 1
  [ "$(tr ',-' '\n' < "$siblings" | grep -c .)" -gt 1 ]
}

fixture_metadata() {
  python3 - "${FIXTURE}/run_metadata.json" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

# Faults derived from the fixture's own placement, so they hold on any host: the recorded
# Java cores split by hyperthread, Java keeping the lowest sibling of each and python-service
# taking the others, as in the suite's case 01. Empty without SMT.
derive_fault_values() {
  # shellcheck disable=SC2034  # read by the sourced topology helpers
  CPU_PIN_LOG=/dev/null
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/load-testing/lib/topology.sh"
  local java_cpuset cpu core sibs sib
  java_cpuset=$(fixture_metadata cores_used_by_suite.transaction_service_cpuset)
  FAULT_SMT_JAVA=""
  FAULT_SMT_PYTHON=""
  if host_has_smt; then
    declare -A seen=()
    while read -r cpu; do
      core=$(topo_core_id "$cpu")
      if [ -z "$core" ] || [ -n "${seen[$core]:-}" ]; then continue; fi
      seen[$core]=1
      sibs=$(topo_siblings_of_cpu "$cpu" | sort -n)
      FAULT_SMT_JAVA="${FAULT_SMT_JAVA}${FAULT_SMT_JAVA:+,}$(head -1 <<< "$sibs")"
      for sib in $(tail -n +2 <<< "$sibs"); do
        FAULT_SMT_PYTHON="${FAULT_SMT_PYTHON}${FAULT_SMT_PYTHON:+,}${sib}"
      done
    done < <(topo_expand_cpuset "$java_cpuset")
  fi
  FAULT_SMT_JAVA_CPUS=$(topo_count_cpus "$FAULT_SMT_JAVA")
  FAULT_SMT_PYTHON_CPUS=$(topo_count_cpus "$FAULT_SMT_PYTHON")
  export FAULT_SMT_JAVA FAULT_SMT_PYTHON FAULT_SMT_JAVA_CPUS FAULT_SMT_PYTHON_CPUS
}

patch_metadata() {
  local metadata="$1" ops="$2"
  [ -n "$ops" ] || return 0
  PATCH_OPS="$ops" python3 - "$metadata" <<'PY'
import json, os, sys

path = sys.argv[1]
data = json.load(open(path))

def parent_of(dotted):
    keys = dotted.split(".")
    node = data
    for key in keys[:-1]:
        node = node[key]
    return node, keys[-1]

for line in os.environ["PATCH_OPS"].splitlines():
    line = line.strip()
    if not line:
        continue
    op, rest = line.split(None, 1)
    if op == "del":
        node, key = parent_of(rest)
        del node[key]
        continue
    dotted, arg = rest.split(None, 1) if " " in rest else (rest, "")
    node, key = parent_of(dotted)
    if op == "set":
        node[key] = arg
    elif op == "append":
        node[key] = f"{node[key]} {arg}"
    else:
        sys.exit(f"unknown metadata operation: {line}")

json.dump(data, open(path, "w"), indent=2)
PY
}

record() {
  local name="$1" desc="$2" guard="$3" outcome="$4" rc="$5" verdict="$6"
  printf '%s,"%s","%s","%s",%s,%s\n' "$name" "$desc" "$guard" "$outcome" "$rc" "$verdict" >> "$REPORT_CSV"
  echo "    ${verdict}: ${outcome}"
  case "$verdict" in
    PASS) PASSED=$((PASSED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    *)    FAILED=$((FAILED + 1)) ;;
  esac
}

stop_measured_stack() {
  RUN_RESULTS_DIR="$1" docker compose -f "${REPO_ROOT}/docker-compose.yml" --profile loadgen down \
    >/dev/null 2>&1 || true
}

run_case() {
  local case_file="$1" name
  name=$(basename "$case_file" .case)

  local DESCRIPTION EXPECT_GUARD EXPECT_REFUSAL PATCH_METADATA SETUP REQUIRES ENV
  DESCRIPTION=""; EXPECT_GUARD=""; EXPECT_REFUSAL=""; PATCH_METADATA=""; SETUP=""; REQUIRES=""; ENV=""
  # shellcheck disable=SC1090  # case files are data, resolved at run time
  . "$case_file"
  local expected="${EXPECT_GUARD:-${EXPECT_REFUSAL:+refusal: ${EXPECT_REFUSAL}}}"

  echo ""
  echo "=== ${CHECK_NAME}/${name}: ${DESCRIPTION}"
  if [ "$REQUIRES" = "smt" ] && ! host_has_smt; then
    record "$name" "$DESCRIPTION" "$expected" "host has no SMT; fault not expressible" "-" "SKIP"
    return
  fi
  echo "    expects ${expected:-a clean run}"

  local case_dir="${SCRATCH}/${name}"
  local run_dir="${case_dir}/results"
  # The metadata is all either check reads at the case slice (explicit rates, no plateau),
  # so a large suite run is not copied eleven times.
  mkdir -p "$run_dir"
  cp "${FIXTURE}/run_metadata.json" "$run_dir/"
  if ! patch_metadata "${run_dir}/run_metadata.json" "$PATCH_METADATA" 2> "${case_dir}/patch.err"; then
    record "$name" "$DESCRIPTION" "$expected" "fixture could not be patched: $(head -1 "${case_dir}/patch.err")" "-" "FAIL"
    return
  fi

  if [ "$SETUP" = "stack-up" ] && ! RUN_RESULTS_DIR="$run_dir" \
      docker compose -f "${REPO_ROOT}/docker-compose.yml" up -d python-service > "${case_dir}/setup.log" 2>&1; then
    stop_measured_stack "$run_dir"
    record "$name" "$DESCRIPTION" "$expected" "the measured stack could not be started for the case" "-" "FAIL"
    return
  fi

  local rc=0
  # shellcheck disable=SC2086  # word splitting is how the VAR=VALUE lists are applied
  env $DEFAULT_ENV $ENV timeout "$CASE_TIMEOUT" "${REPO_ROOT}/load-testing/${SCRIPT}" "$run_dir" \
    > "${case_dir}/run.log" 2>&1 || rc=$?
  stop_measured_stack "$run_dir"

  local failures="${run_dir}/${FAILURES_FILE}"
  if [ -z "$EXPECT_GUARD" ] && [ -z "$EXPECT_REFUSAL" ]; then
    if [ "$rc" -ne 0 ] || [ -s "$failures" ]; then
      record "$name" "$DESCRIPTION" "none" "aborted on the unmodified fixture" "$rc" "FAIL"
    elif ! (cd "$run_dir" && control_check) >> "${case_dir}/run.log" 2>&1; then
      record "$name" "$DESCRIPTION" "none" "ran, but its output failed the control check" "$rc" "FAIL"
    else
      record "$name" "$DESCRIPTION" "none" "ran clean" "$rc" "PASS"
    fi
    return
  fi

  if [ "$rc" -eq 0 ]; then
    record "$name" "$DESCRIPTION" "$expected" "run completed despite the fault" "$rc" "FAIL"
  elif [ -n "$EXPECT_GUARD" ]; then
    if [ -f "$failures" ] && grep -qF "$EXPECT_GUARD" "$failures"; then
      record "$name" "$DESCRIPTION" "$expected" "rejected by ${EXPECT_GUARD}" "$rc" "PASS"
    else
      record "$name" "$DESCRIPTION" "$expected" "aborted, but not via ${EXPECT_GUARD}" "$rc" "FAIL"
    fi
  elif grep -qF "$EXPECT_REFUSAL" "${case_dir}/run.log"; then
    record "$name" "$DESCRIPTION" "$expected" "refused before measuring" "$rc" "PASS"
  else
    record "$name" "$DESCRIPTION" "$expected" "aborted without the expected refusal" "$rc" "FAIL"
  fi
}

run_guard_cases() {
  FIXTURE=$(resolve_fixture "${1:-}") || exit 2
  SCRATCH="${GUARD_ROOT}/scratch/${CHECK_NAME}"
  REPORT_DIR="${GUARD_ROOT}/results"
  REPORT_CSV="${REPORT_DIR}/guard_verification_${CHECK_NAME}.csv"
  REPORT_MD="${REPORT_DIR}/guard_verification_${CHECK_NAME}.md"
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH" "$REPORT_DIR"
  echo "case,description,expected,outcome,exit_code,verdict" > "$REPORT_CSV"
  PASSED=0; FAILED=0; SKIPPED=0

  derive_fault_values
  echo "[*] ${CHECK_NAME} guard cases against copies of ${FIXTURE}"

  local case_file
  for case_file in "${GUARD_ROOT}/cases/${CHECK_NAME}"/*.case; do
    run_case "$case_file"
  done

  {
    echo "# Guard verification: ${SCRIPT}"
    echo ""
    echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(uname -sr), against copies of \`${FIXTURE}\`."
    echo ""
    echo "Each case patches one recorded setting in a copy of a finished suite run and runs"
    echo "${SCRIPT} against it. PASS means the named guard rejected the run, or the script"
    echo "refused it before measuring; for the unmodified case it means the check completed"
    echo "with no guard firing."
    echo ""
    echo "| Case | Fault | Expected | Outcome | Verdict |"
    echo "|---|---|---|---|---|"
    tail -n +2 "$REPORT_CSV" | python3 -c '
import csv, sys
for r in csv.reader(sys.stdin):
    print("| " + " | ".join([r[0], r[1], "`" + r[2] + "`", r[3], r[5]]) + " |")
'
    echo ""
    echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped."
  } > "$REPORT_MD"

  echo ""
  echo "[+] ${CHECK_NAME}: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped. Report: ${REPORT_MD}"
  [ "$FAILED" -eq 0 ]
}
