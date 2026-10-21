#!/usr/bin/env bash
# predict_proba composition check against one run-suite.sh run: lib/predict_composition.py
# in one-off containers of the python-service image, on the suite run's Python cpuset and
# CPU quota and in its recorded power state, writing predict_composition.json into that
# run's directory for analyze-results.py's table 9. The measured stack must be down.
#
# Usage: ./run-predict-composition.sh [SUITE_RUN_DIR]     (default: this host's latest suite run)
#
# COMPOSITION_REPS (default 7) repetitions, each in a fresh `docker compose run --rm`
# container (the analogue of the suite's restart) with the tier order shuffled, after a
# thermal check and between power checks, with the suite's cooldown between them.
# COMPOSITION_N (default 2000) and COMPOSITION_WARMUP (default 200) set the timed and
# warm-up calls per stream and tier. Aborts go to composition_failures_log.txt, never to
# the suite's run_failures_log.txt.
set -euo pipefail
exec < /dev/null

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

for _req_cmd in docker shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}." >&2
    exit 1
  fi
done
for _req_lib in lib/host-provenance.sh lib/power-state.sh lib/thermal.sh lib/run-layout.sh lib/predict_composition.py; do
  if [ ! -r "$_req_lib" ]; then
    echo "[!] Required helper not found: ${_req_lib}." >&2
    exit 1
  fi
done
. lib/host-provenance.sh
. lib/power-state.sh
. lib/thermal.sh
. lib/run-layout.sh

for _sysfs_var in THERMAL_SYSFS_ROOT POWER_SYSFS_ROOT; do
  if [ "${!_sysfs_var:-/sys}" != "/sys" ]; then
    echo "[!] ${_sysfs_var} is set to '${!_sysfs_var}'. The composition check reads the live host only;" >&2
    echo "    unset it before running." >&2
    exit 1
  fi
done

COMPOSITION_N="${COMPOSITION_N:-2000}"
COMPOSITION_WARMUP="${COMPOSITION_WARMUP:-200}"
# The suite's REPS_SCAN default.
COMPOSITION_REPS="${COMPOSITION_REPS:-7}"
COMPOSITION_TIERS="5 10 20 28"
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"
COMPOSE_FILE="../docker-compose.yml"
for _var in COMPOSITION_N COMPOSITION_WARMUP COMPOSITION_REPS THERMAL_WARN_C THERMAL_CRIT_C THERMAL_COOLDOWN_S \
  MAX_THERMAL_COOLDOWNS THERMAL_MAX_COOLDOWNS_EXTENDED; do
  if ! [[ "${!_var}" =~ ^[0-9]+$ ]] || [ "${!_var}" -lt 1 ]; then
    echo "[!] ${_var}='${!_var}' is not a positive integer." >&2
    exit 1
  fi
done

if [ "$#" -gt 0 ]; then
  RUN_DIR="$1"
else
  _runs=(../results/suite_"$(run_host_label)"_*)
  RUN_DIR="${_runs[-1]}"
fi
if [ ! -f "${RUN_DIR}/run_metadata.json" ]; then
  echo "[!] ${RUN_DIR} is not a run-suite.sh run directory." >&2
  exit 1
fi
RUN_DIR=$(cd "$RUN_DIR" && pwd)
OUT_FILE="${RUN_DIR}/predict_composition.json"
REP_DIR="${RUN_DIR}/predict_composition_reps"
ENV_TRACE_LOG="${RUN_DIR}/composition_env_trace_log.txt"
FAILURES_LOG="${RUN_DIR}/composition_failures_log.txt"
CURRENT_REP="none"

suite_metadata() {
  python3 - "${RUN_DIR}/run_metadata.json" "$1" <<'PYEOF'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)
PYEOF
}

# The suite's cpuset and CPU quota rather than compose's current defaults, so the check runs
# on the cores, and under the limit, the measured service ran with.
PY_CPUSET=$(suite_metadata cores_used_by_suite.python_service_cpuset)
if [ -z "$PY_CPUSET" ] || [ "$PY_CPUSET" = "unknown" ]; then
  echo "[!] ${RUN_DIR} recorded no Python cpuset." >&2
  exit 1
fi
PY_CPUS=$(suite_metadata cores_used_by_suite.python_service_cpus_quota)
if [ -z "$PY_CPUS" ] || [ "$PY_CPUS" = "unknown" ]; then
  echo "[!] ${RUN_DIR} recorded no Python CPU quota." >&2
  exit 1
fi

compose() {
  RUN_RESULTS_DIR="$RUN_DIR" PYTHON_CPUSET="$PY_CPUSET" PYTHON_CPUS="$PY_CPUS" \
    docker compose -f "$COMPOSE_FILE" "$@"
}

# One line per abort, tagged with the rep, in composition_failures_log.txt; the merged file
# is written only after every rep, so an abort leaves none.
abort_suite() {
  local label="$1"; shift
  echo "  [FATAL] ${label}: $*" >&2
  echo "$(thermal_ts) rep=${CURRENT_REP} [FATAL] ${label}: $*" >> "$FAILURES_LOG"
  rm -f "$OUT_FILE"
  exit 1
}

_log_uncaught_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$FAILURES_LOG" ]; then
    echo "$(thermal_ts) rep=${CURRENT_REP} [FATAL] [uncaught] composition check aborted with status ${rc}" \
         "before any check logged a reason." >> "$FAILURES_LOG"
  fi
  return 0
}

# Compared with the suite's inference telemetry, so it must run in the power state the
# suite recorded.
SUITE_POWER_STATE=$(suite_metadata power_state.snapshot)
if [ -z "$SUITE_POWER_STATE" ]; then
  echo "[!] ${RUN_DIR} recorded no CPU power state, so the composition check cannot be matched to it." >&2
  exit 1
fi
require_prepared_host "$(suite_metadata power_state.turbo_required)"
if [ "$POWER_STATE_AT_START" != "$SUITE_POWER_STATE" ]; then
  echo "[!] The CPU power state differs from the one ${RUN_DIR} ran in:" >&2
  echo "      suite run: ${SUITE_POWER_STATE}" >&2
  echo "      now:       ${POWER_STATE_AT_START}" >&2
  exit 1
fi
COOLDOWN_S="${COMPOSITION_COOLDOWN_S:-$(suite_metadata suite_config.cooldown_s)}"
if ! [[ "$COOLDOWN_S" =~ ^[0-9]+$ ]]; then
  echo "[!] ${RUN_DIR} recorded no suite_config.cooldown_s; set COMPOSITION_COOLDOWN_S." >&2
  exit 1
fi

# Containers of the measured services, from any compose project: one running would share
# the host with the check.
measured_stack_containers() {
  docker ps --format '{{.Label "com.docker.compose.service"}} {{.Names}}' 2>/dev/null \
    | awk '$1 == "python-service" || $1 == "transaction-service" || $1 == "k6" { print $2 }' \
    | paste -sd, - || true
}

: > "$FAILURES_LOG"
trap _log_uncaught_exit EXIT

_running=$(measured_stack_containers)
if [ -n "$_running" ]; then
  abort_suite "[stack]" "the measured stack is running (${_running}); stop it ('docker compose down')" \
    "so the check does not share the host with it."
fi

# The already-built image is required: letting compose run build it here could measure
# code other than what the suite ran.
PY_IMAGE=$(compose config --images 2>/dev/null | grep -E '(^|[-_])python-service$' | head -1 || true)
if [ -z "$PY_IMAGE" ] || ! PY_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$PY_IMAGE" 2>/dev/null); then
  abort_suite "[image]" "the python-service image (${PY_IMAGE:-unresolved}) is not built; run the suite" \
    "or 'docker compose build' first."
fi

echo "[*] predict_proba composition: image ${PY_IMAGE} (${PY_IMAGE_ID}), cpuset ${PY_CPUSET}," \
     "quota ${PY_CPUS}, N=${COMPOSITION_N} x ${COMPOSITION_REPS} rep(s) -> ${OUT_FILE}"
rm -f "$OUT_FILE"
mkdir -p "$REP_DIR"
rm -f "${REP_DIR}"/rep*.json

# One repetition in a fresh container, tiers in a fresh order.
composition_rep() {
  local rep="$1" order running
  CURRENT_REP="$rep"
  running=$(measured_stack_containers)
  if [ -n "$running" ]; then
    abort_suite "[stack] rep=${rep}" "the measured stack started during the check (${running})."
  fi
  check_thermal_safety "composition rep=${rep}"
  record_env_sample "composition_rep${rep}_start"
  check_power_state "composition rep=${rep} start"
  order=$(shuf -e $COMPOSITION_TIERS | paste -sd, -)
  echo "[*] --- Composition repetition ${rep}/${COMPOSITION_REPS}: tiers ${order} ---"
  if ! compose run --rm --no-deps -T \
      -v "${LIB_DIR}:/harness:ro" -v "${RUN_DIR}:/out" \
      python-service python /harness/predict_composition.py \
        --out "/out/predict_composition_reps/rep${rep}.json" --rep "$rep" --tiers "$order" \
        --models-dir /app/models --n "$COMPOSITION_N" --warmup "$COMPOSITION_WARMUP" \
        --expect-cpuset "$PY_CPUSET" --expect-cpu-quota "$PY_CPUS" --image-id "$PY_IMAGE_ID"; then
    abort_suite "[composition] rep=${rep}" "predict_composition.py exited non-zero (CPU affinity, CPU quota" \
      "or n_jobs check failed, or the measurement did not complete)."
  fi
  check_power_state "composition rep=${rep} end"
  record_env_sample "composition_rep${rep}_end"
  if [ ! -s "${REP_DIR}/rep${rep}.json" ]; then
    abort_suite "[composition] rep=${rep}" "no ${REP_DIR}/rep${rep}.json was written."
  fi
}

for rep in $(seq 1 "$COMPOSITION_REPS"); do
  composition_rep "$rep"
  if [ "$rep" -lt "$COMPOSITION_REPS" ]; then sleep "$COOLDOWN_S"; fi
done
CURRENT_REP="none"

_rep_files=()
for rep in $(seq 1 "$COMPOSITION_REPS"); do _rep_files+=("${REP_DIR}/rep${rep}.json"); done
if ! python3 "${LIB_DIR}/predict_composition.py" --out "$OUT_FILE" --merge "${_rep_files[@]}"; then
  abort_suite "[composition]" "the rep files could not be merged into ${OUT_FILE}."
fi
echo "[+] predict_proba composition (${COMPOSITION_REPS} rep(s)) written to ${OUT_FILE}"
