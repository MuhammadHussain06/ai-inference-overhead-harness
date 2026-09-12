#!/usr/bin/env bash
set -uo pipefail

# Checks that the harness's abort guards fire. Each case misconfigures one pinned setting
# the suite claims to enforce, runs a minimal slice of run-suite.sh against that
# configuration, and records whether the expected guard rejected it.
#
# A guard that never fires is indistinguishable from a guard that cannot fail, and both
# report a clean run. These cases are what separates the two. Case 00 runs unmodified and
# must pass, so a suite where every case aborts is itself reported as a failure.
#
# Nothing here touches ../results: each case runs against a generated copy of the compose
# configuration whose bind mounts and results directory point inside this folder.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

for _req_cmd in docker python3 timeout; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}." >&2
    exit 1
  fi
done

REPO_ROOT=$(cd .. && pwd)
SCRATCH="$(pwd)/scratch"
REPORT_DIR="$(pwd)/results"
CASE_TIMEOUT="${CASE_TIMEOUT_S:-600}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH" "$REPORT_DIR"

REPORT_MD="${REPORT_DIR}/guard_verification_report.md"
REPORT_CSV="${REPORT_DIR}/guard_verification_report.csv"
echo "case,description,stage,expected_guard,outcome,exit_code,verdict" > "$REPORT_CSV"

# Baseline cpusets for this host. The compose defaults name whole physical cores on one
# machine only; on any other host every case would abort on the baseline rather than on its
# own fault. The defaults are used when they still hold here, and recommend-cpusets.sh
# supplies values when they do not.
# The checks below are reused to test the baseline rather than to reject a run, so
# abort_suite records instead of exiting and each call is read from what it recorded.
# shellcheck disable=SC2034  # read by the sourced topology helpers
CPU_PIN_LOG=/dev/null
BASELINE_ABORT=""
abort_suite() { BASELINE_ABORT="$*"; return 1; }
. ../load-testing/lib/topology.sh

compose_default() {
  docker compose -f "${REPO_ROOT}/docker-compose.yml" --profile loadgen config 2>/dev/null \
    | awk -v svc="  ${1}:" -v key="${2}:" '
        $0 == svc { in_svc = 1; next }
        in_svc && /^  [a-zA-Z0-9_-]+:$/ { in_svc = 0 }
        in_svc && $1 == key { sub(/^ +[a-zA-Z0-9_-]+: */, ""); gsub(/"/, ""); print; exit }
      '
}

defaults_hold_here() {
  local svc
  for svc in python-service transaction-service k6; do
    BASELINE_ABORT=""
    verify_service_cpuset "baseline" "$svc" "$(compose_default "$svc" cpuset)" "" >/dev/null 2>&1
    [ -z "$BASELINE_ABORT" ] || return 1
  done
}

BASELINE=""
if defaults_hold_here; then
  BASELINE_SOURCE="docker-compose.yml defaults"
elif RECOMMENDED=$(../load-testing/recommend-cpusets.sh 2>"${SCRATCH}/recommend.err"); then
  BASELINE=$(sed -n 's/^export //p' <<< "$RECOMMENDED" | tr -d '"' | tr '\n' ' ')
  BASELINE_SOURCE="recommend-cpusets.sh"
  # shellcheck disable=SC2086,SC2163  # the baseline is a VAR=VALUE list, applied by word splitting
  export $BASELINE
else
  echo "[!] The compose defaults do not describe whole physical cores on this host, and no" >&2
  echo "    replacement could be derived for it:" >&2
  sed 's/^/      /' "${SCRATCH}/recommend.err" >&2
  echo "    Every case would then abort on the baseline rather than on its own fault, which" >&2
  echo "    says nothing about the guards. Run this on a host the harness itself can run on." >&2
  exit 2
fi

# First CPU of python-service's cpuset: on an SMT host its sibling is in the cpuset too,
# so pinning to it alone leaves a half-owned core on any topology.
PYTHON_BASELINE_CPUSET="${PYTHON_CPUSET:-$(compose_default python-service cpuset)}"
FAULT_HALF_CORE=$(tr ',' '\n' <<< "$PYTHON_BASELINE_CPUSET" | head -1 | cut -d- -f1)
export FAULT_HALF_CORE PYTHON_BASELINE_CPUSET

echo "[*] Baseline cpusets from ${BASELINE_SOURCE}:"
echo "    python=${PYTHON_BASELINE_CPUSET} java=${JAVA_CPUSET:-$(compose_default transaction-service cpuset)} k6=${K6_CPUSET:-$(compose_default k6 cpuset)}"

PASSED=0
FAILED=0
SKIPPED=0

# Some faults only exist on a host with hyperthreading: on a machine where every logical
# CPU is its own physical core, a cpuset cannot take half of one. Those cases are skipped
# rather than counted, since the guard is untested here, not proven absent.
host_has_smt() {
  local siblings="/sys/devices/system/cpu/cpu0/topology/thread_siblings_list"
  [ -r "$siblings" ] || return 1
  [ "$(tr ',-' '\n' < "$siblings" | grep -c .)" -gt 1 ]
}

# Writes a compose configuration for one case: the repo's own file resolved with the
# case's environment, then the requested env value replaced, then every bind mount
# repointed into this case's scratch directory.
render_compose() {
  local case_env="$1" patch_set_env="$2" out="$3" case_results="$4"

  # shellcheck disable=SC2086  # word splitting is how the case's VAR=VALUE list is applied
  if ! env $BASELINE $case_env docker compose -f "${REPO_ROOT}/docker-compose.yml" --profile loadgen config \
       > "${out}.raw" 2>"${out}.err"; then
    return 1
  fi

  REPO_ROOT="$REPO_ROOT" CASE_RESULTS="$case_results" PATCH_SET_ENV="$patch_set_env" \
  python3 - "${out}.raw" "$out" <<'PY'
import os, re, sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()

# Repoint bind mounts so a guard that fails to fire cannot write into the real dataset.
repo_results = os.path.join(os.environ["REPO_ROOT"], "results")
case_results = os.environ["CASE_RESULTS"]
lines = [re.sub(r"(source: )" + re.escape(repo_results), r"\1" + case_results, ln) for ln in lines]

# Replace one service's environment value, for faults that are not expressible as a
# compose variable (the JVM options and the tier list are literals in the compose file).
spec = os.environ.get("PATCH_SET_ENV", "")
if spec:
    service, key, value = spec.split(":", 2)
    in_service = in_env = False
    for i, ln in enumerate(lines):
        if re.match(r"^  \S+:$", ln):
            in_service = ln.strip().rstrip(":") == service
            in_env = False
            continue
        if in_service and re.match(r"^    \S+:$", ln):
            in_env = ln.strip() == "environment:"
            continue
        if in_env and re.match(r"^      " + re.escape(key) + r":", ln):
            lines[i] = f"      {key}: {value}"
            break
    else:
        sys.exit(f"patch target not found: {spec}")

open(dst, "w").write("\n".join(lines) + "\n")
PY
}

run_case() {
  local case_file="$1"
  local name; name=$(basename "$case_file" .case)

  local DESCRIPTION STAGE EXPECT_GUARD ENV PATCH_SET_ENV REQUIRES
  DESCRIPTION=""; STAGE=""; EXPECT_GUARD=""; ENV=""; PATCH_SET_ENV=""; REQUIRES=""
  # shellcheck disable=SC1090  # case files are data, resolved at run time
  . "$case_file"

  if [ "$REQUIRES" = "smt" ] && ! host_has_smt; then
    echo ""
    echo "=== ${name}: ${DESCRIPTION}"
    record "$name" "$DESCRIPTION" "$STAGE" "$EXPECT_GUARD" "host has no SMT; fault not expressible" "-" "SKIP"
    return
  fi

  local case_dir="${SCRATCH}/${name}"
  local case_results="${case_dir}/results"
  mkdir -p "${case_results}/gc-logs"

  echo ""
  echo "=== ${name}: ${DESCRIPTION}"
  echo "    expects ${EXPECT_GUARD:-a clean run} (${STAGE})"

  local compose="${case_dir}/compose.yml"
  if ! render_compose "$ENV" "$PATCH_SET_ENV" "$compose" "$case_results"; then
    record "$name" "$DESCRIPTION" "$STAGE" "$EXPECT_GUARD" "compose configuration rejected" "-" "FAIL"
    return
  fi

  local rc=0
  # Baseline first, so a case's own assignment of the same variable wins.
  # shellcheck disable=SC2086  # word splitting is how the case's VAR=VALUE list is applied
  env $BASELINE $ENV \
    COMPOSE_FILE_OVERRIDE="$compose" \
    RESULTS_DIR_OVERRIDE="$case_results" \
    TARGETS_OVERRIDE="calibration" \
    CONCURRENCY_OVERRIDE="1" \
    REPS_BASELINE_OVERRIDE=1 \
    REPS_SCAN_OVERRIDE=1 \
    BASELINE_ITERATIONS_OVERRIDE=1 \
    SCAN_ITERATIONS_PER_VU_OVERRIDE=1 \
    WARMUP_ITERATIONS_PER_TARGET_OVERRIDE=1 \
    timeout "$CASE_TIMEOUT" ../load-testing/run-suite.sh > "${case_dir}/run.log" 2>&1 || rc=$?

  docker compose -f "$compose" down >/dev/null 2>&1 || true

  local failures="${case_results}/run_failures_log.txt"
  local guard_line=""
  [ -f "$failures" ] && guard_line=$(grep -F -m1 "${EXPECT_GUARD:-[FATAL]}" "$failures" 2>/dev/null || true)

  if [ -z "$EXPECT_GUARD" ]; then
    # The unmodified case: the run must complete and leave the failures log empty.
    if [ "$rc" -eq 0 ] && [ ! -s "$failures" ]; then
      record "$name" "$DESCRIPTION" "$STAGE" "none" "ran clean" "$rc" "PASS"
    else
      record "$name" "$DESCRIPTION" "$STAGE" "none" "aborted on an unmodified configuration" "$rc" "FAIL"
    fi
    return
  fi

  if [ "$rc" -eq 0 ]; then
    record "$name" "$DESCRIPTION" "$STAGE" "$EXPECT_GUARD" "run completed despite the fault" "$rc" "FAIL"
  elif [ -z "$guard_line" ]; then
    record "$name" "$DESCRIPTION" "$STAGE" "$EXPECT_GUARD" "aborted, but not via ${EXPECT_GUARD}" "$rc" "FAIL"
  else
    record "$name" "$DESCRIPTION" "$STAGE" "$EXPECT_GUARD" "rejected by ${EXPECT_GUARD}" "$rc" "PASS"
  fi
}

record() {
  local name="$1" desc="$2" stage="$3" guard="$4" outcome="$5" rc="$6" verdict="$7"
  printf '%s,"%s",%s,"%s","%s",%s,%s\n' "$name" "$desc" "$stage" "$guard" "$outcome" "$rc" "$verdict" \
    >> "$REPORT_CSV"
  echo "    ${verdict}: ${outcome}"
  case "$verdict" in
    PASS) PASSED=$((PASSED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    *)    FAILED=$((FAILED + 1)) ;;
  esac
}

for case_file in cases/*.case; do
  run_case "$case_file"
done

{
  echo "# Guard verification"
  echo ""
  echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(uname -sr)."
  echo ""
  echo "Baseline cpusets from ${BASELINE_SOURCE}: python \`${PYTHON_BASELINE_CPUSET}\`."
  echo ""
  echo "Each case misconfigures one pinned setting and runs a minimal slice of the suite"
  echo "against it. PASS means the named guard rejected the run; for the unmodified case it"
  echo "means the run completed with no guard firing."
  echo ""
  echo "| Case | Fault | Stage | Guard | Outcome | Verdict |"
  echo "|---|---|---|---|---|---|"
  tail -n +2 "$REPORT_CSV" | python3 -c '
import csv, sys
for r in csv.reader(sys.stdin):
    print("| " + " | ".join([r[0], r[1], r[2], "`" + r[3] + "`", r[4], r[6]]) + " |")
'
  echo ""
  echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped."
  echo ""
  echo "Not covered: a configuration whose pinned options are present but never reach the"
  echo "JVM. The guard checks that case through the flag origin the JVM reports, which no"
  echo "compose-level fault can reproduce."
} > "$REPORT_MD"

echo ""
echo "[+] ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped. Report: ${REPORT_MD}"
[ "$FAILED" -eq 0 ]