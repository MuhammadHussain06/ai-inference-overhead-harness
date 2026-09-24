#!/usr/bin/env bash
set -euo pipefail

# Detaches stdin: a backgrounded docker compose invocation that inherits the
# terminal's stdin gets stopped by SIGTTIN the moment it tries to read it.
exec < /dev/null

# Isolates the drivers of thread-dispatch time at VUS=64 / TARGET=28 across four arms:
# thread_limiter, cpuset, workers, and workers with aggregate token capacity held constant.
# python-service takes interleaved even physical cores so it stays SMT-disjoint from Java and k6.

cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

for _req_lib in lib/host-provenance.sh lib/jvm-pins.sh lib/topology.sh lib/thermal.sh \
  lib/warmup_gate.py lib/k6_filter.py; do
  if [ ! -r "$_req_lib" ]; then
    echo "[!] Required helper not found: ${_req_lib}. Aborting before touching any containers." >&2
    exit 1
  fi
done

# Host-state provenance for ablation_run_metadata.json, the CPU-topology and JVM
# collector/thread-pool guards every cell is gated on, and the thermal guard and telemetry.
. lib/host-provenance.sh
. lib/jvm-pins.sh
. lib/topology.sh
. lib/thermal.sh

# Reading topology or temperatures from anywhere but the live tree would verify core
# placement, or guard heat, on a host that is not the one running the containers.
for _sysfs_var in TOPO_SYSFS_ROOT THERMAL_SYSFS_ROOT; do
  if [ "${!_sysfs_var:-/sys}" != "/sys" ]; then
    echo "[!] ${_sysfs_var} is set to '${!_sysfs_var}'. The ablation reads the live host only;" >&2
    echo "    unset it before running." >&2
    exit 1
  fi
done

IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- see README Limitations on cpu-pin verification under WSL2." >&2
fi

# Both overridable so the fault-injection suite can run the ablation against a patched
# configuration without writing into a real dataset.
COMPOSE_FILE="${COMPOSE_FILE_OVERRIDE:-../docker-compose.yml}"
RESULTS_DIR="${RESULTS_DIR_OVERRIDE:-../results}"
# k6 writes its full, unfiltered trail here (container-visible as /results/raw);
# finalize_result() filters + gzips each file into RESULTS_DIR and deletes the
# raw copy right after, so this stays near-empty except mid-cell. Shared
# scratch with run-suite.sh's own raw dir -- cleared at whichever starts first.
RAW_RESULTS_DIR="${RESULTS_DIR}/raw"
rm -rf "$RAW_RESULTS_DIR"
mkdir -p "$RESULTS_DIR" "$RAW_RESULTS_DIR"

# Moves a prior ablation run's own files into a timestamped subdirectory before this
# run writes any. Scoped to ablation_* -- RESULTS_DIR is shared with run-suite.sh, and
# an unscoped sweep here would archive a main-suite run's results out from under it.
if compgen -G "${RESULTS_DIR}/ablation_*.json" > /dev/null 2>&1 || compgen -G "${RESULTS_DIR}/ablation_*.json.gz" > /dev/null 2>&1 \
    || [ -f "${RESULTS_DIR}/ablation_run_order_log.txt" ]; then
  ABLATION_ARCHIVE_DIR="${RESULTS_DIR}/archive/$(date +%Y%m%d_%H%M%S)_ablation"
  mkdir -p "$ABLATION_ARCHIVE_DIR"
  find "$RESULTS_DIR" -maxdepth 1 -name 'ablation_*.json' -exec mv {} "$ABLATION_ARCHIVE_DIR/" \;
  find "$RESULTS_DIR" -maxdepth 1 -name 'ablation_*.json.gz' -exec mv {} "$ABLATION_ARCHIVE_DIR/" \;
  find "$RESULTS_DIR" -maxdepth 1 -name 'ablation_*_log.txt' -exec mv {} "$ABLATION_ARCHIVE_DIR/" \;
  echo "[*] Archives previous ablation run's results to ${ABLATION_ARCHIVE_DIR}"
fi

# The three metrics in analyze-ablation.py's METRICS dict; http_req_duration, which
# calibration, the warm-up gate and the error table all read back; and the counters
# that tell a truncated or failing cell from a clean one.
ABLATION_KEEP_METRICS="python_thread_dispatch_time_ms,python_model_inference_time_ms,python_total_time_ms,http_req_duration,dropped_iterations,request_http_error,request_timeout_error"

# Separate log files from run-suite.sh's, so an ablation run never trips
# analyze-results.py's hard-fail-on-any-failures-log-entry check for the main
# suite's own dataset.
ORDER_LOG="${RESULTS_DIR}/ablation_run_order_log.txt"
: > "$ORDER_LOG"
METADATA_FILE="${RESULTS_DIR}/ablation_run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/ablation_run_failures_log.txt"
# Both analysis scripts refuse to run if this log is non-empty, so any abort must write to
# it. This catch-all fires last, only when nothing more specific already logged a reason.
_log_uncaught_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$FAILURES_LOG" ]; then
    echo "  [FATAL] [uncaught] run aborted with status ${rc} before any cell-level check logged a" \
         "reason -- treat this dataset as incomplete." >> "$FAILURES_LOG"
  fi
  return 0
}
trap _log_uncaught_exit EXIT

: > "$FAILURES_LOG"
CPU_PIN_LOG="${RESULTS_DIR}/ablation_cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"

ABLATION_TARGET="${ABLATION_TARGET_OVERRIDE:-28}"
ABLATION_VUS="${ABLATION_VUS_OVERRIDE:-64}"
# Recorded in metadata as a reference value only: calibrate_ablation_cell() sets the
# ABLATION_ITER_PER_VU that every measured cell is actually run at.
ITERATIONS_PER_VU="${ABLATION_ITERATIONS_PER_VU_OVERRIDE:-100}"

# Every ablation cell runs this same TARGET/VUS, so per-vu-iterations' tail
# taper (see run-suite.sh's calibration comment) applies here too. Throughput is
# each arm's own manipulated variable, so every (arm, value) cell is calibrated
# separately, once, in a pass before the reps (see calibrate_ablation_cells()),
# and every rep of the cell runs that count.
ABLATION_CALIB_ITER_PER_VU="${ABLATION_CALIB_ITER_PER_VU_OVERRIDE:-500}"
ABLATION_CALIB_TARGET_DURATION_S="${ABLATION_CALIB_TARGET_DURATION_S_OVERRIDE:-60}"
# Replicates per arm value; n=7 is what analyze-ablation.py's Mann-Whitney tests and
# bootstrap CIs are sized against.
REPS_ABLATION="${REPS_ABLATION_OVERRIDE:-7}"

# ACPI/DPTF negotiation can fail at boot, leaving the OS blind to platform thermal
# policy, so check_thermal_safety() reads /sys/class/thermal directly rather than
# trusting a userspace daemon: a long pinned-core run then pauses or aborts instead
# of hard-hanging.
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
# Rounds beyond MAX_THERMAL_COOLDOWNS are only granted while still cooling
# (check_thermal_safety), so this bounds the worst case rather than setting the
# common one.
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"

# Command substitution in a for word-list is not an errexit context, so integer overrides
# must be validated explicitly before use.
for _intvar in REPS_ABLATION ABLATION_VUS ITERATIONS_PER_VU ABLATION_CALIB_ITER_PER_VU ABLATION_CALIB_TARGET_DURATION_S \
  THERMAL_WARN_C THERMAL_CRIT_C THERMAL_COOLDOWN_S MAX_THERMAL_COOLDOWNS THERMAL_MAX_COOLDOWNS_EXTENDED; do
  if [ -n "${!_intvar+x}" ] && { ! [[ "${!_intvar}" =~ ^[0-9]+$ ]] || [ "${!_intvar}" -lt 1 ]; }; then
    echo "[!] ${_intvar} must be a positive integer, got '${!_intvar}'." >&2
    exit 1
  fi
done
if [ "$THERMAL_MAX_COOLDOWNS_EXTENDED" -lt "$MAX_THERMAL_COOLDOWNS" ]; then
  echo "[!] THERMAL_MAX_COOLDOWNS_EXTENDED (${THERMAL_MAX_COOLDOWNS_EXTENDED}) must be >=" \
       "MAX_THERMAL_COOLDOWNS (${MAX_THERMAL_COOLDOWNS})." >&2
  exit 1
fi
COOLDOWN_S=10
ANYIO_DEFAULT_TOKENS=40
EXPECTED_TIERS="5,10,20,28"
# Matches docker-compose.yml's default, so every arm's control cell is the same
# configuration E1 and E2 measured. An ablation run at a different worker count would
# characterise a service the main suite never benchmarked.
CONTROL_WORKERS=3
# Defaults name whole physical cores on the host they were picked for; recommend-cpusets.sh
# prints values for another host, and verify_service_cpuset() rejects a cell whose cpuset
# splits a core. Each quota is derived from its own cpuset, since a larger one is clamped
# by the kernel and would misreport the limit applied.
CONTROL_CPUSET="${PYTHON_CPUSET:-0-1,4-5,8-9}"
CONTROL_CPUS="$(topo_count_cpus "$CONTROL_CPUSET").0"
NARROW_CPUSET="${ABLATION_CPUSET_NARROW:-0-1}"
NARROW_CPUS="$(topo_count_cpus "$NARROW_CPUSET").0"
WIDE_CPUSET="${ABLATION_CPUSET_WIDE:-0-1,4-5,8-9,12-13}"
WIDE_CPUS="$(topo_count_cpus "$WIDE_CPUSET").0"

# Sized off the ablation's own VUS so the Java outbound pool is never the
# bottleneck under test. Consumed by docker-compose.yml.
export PYTHON_SERVICE_MAX_CONNECTIONS=$((ABLATION_VUS * 2))

ENV_TRACE_LOG="${RESULTS_DIR}/ablation_env_trace_log.txt"
: > "$ENV_TRACE_LOG"
CALIB_LOG="${RESULTS_DIR}/ablation_calibration_log.txt"
: > "$CALIB_LOG"
# "<arm>:<value>" -> iterations per VU, filled by calibrate_ablation_cells().
declare -A ABLATION_CALIB_CACHE

# arm:value:cpuset:cpus:workers:tokens
# Each arm holds the other mechanisms at the control values above and sweeps one.
# python-service takes whole physical cores (2, 6 or 8 logical CPUs); verify_smt_isolation
# re-checks disjointness per cell because the cpuset arm changes it.
#
# The thread limiter is per process, so the workers arm varies GIL count and aggregate
# token capacity together (3 workers = 3 x 40 tokens). workers_token_matched repeats
# the endpoints with tokens scaled to hold the aggregate near 40, which separates the
# two explanations.
CELLS=(${ABLATION_CELLS_OVERRIDE:-
  "thread_limiter:40:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:40"
  "thread_limiter:64:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:64"
  "thread_limiter:128:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:128"
  "cpuset:${NARROW_CPUSET}:${NARROW_CPUSET}:${NARROW_CPUS}:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:${CONTROL_CPUSET}:${CONTROL_CPUSET}:${CONTROL_CPUS}:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:${WIDE_CPUSET}:${WIDE_CPUSET}:${WIDE_CPUS}:${CONTROL_WORKERS}:${ANYIO_DEFAULT_TOKENS}"
  "workers:1:${CONTROL_CPUSET}:${CONTROL_CPUS}:1:${ANYIO_DEFAULT_TOKENS}"
  "workers:2:${CONTROL_CPUSET}:${CONTROL_CPUS}:2:${ANYIO_DEFAULT_TOKENS}"
  "workers:3:${CONTROL_CPUSET}:${CONTROL_CPUS}:3:${ANYIO_DEFAULT_TOKENS}"
  "workers_token_matched:1:${CONTROL_CPUSET}:${CONTROL_CPUS}:1:40"
  "workers_token_matched:3:${CONTROL_CPUSET}:${CONTROL_CPUS}:3:13"
})

if [ "${#CELLS[@]}" -eq 0 ]; then
  echo "[!] CELLS resolved to no cells -- check ABLATION_CELLS_OVERRIDE." >&2
  exit 1
fi

# Unset by default, which leaves converge_warmup()'s chunked convergence gate in charge.
# Setting it switches warm-up.js to a single fixed-iteration pass and skips that gate,
# for reduced-scale runs where warm-up would otherwise dwarf the cells.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"
WARMUP_ENV_ARGS=(WARMUP_TARGETS="$ABLATION_TARGET" WARMUP_VUS="$ABLATION_VUS")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi

capture_run_metadata() {
  local timestamp git_commit git_dirty cpu_model cpu_count total_mem_kb
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if command -v git >/dev/null 2>&1 && git -C .. rev-parse HEAD >/dev/null 2>&1; then
    git_commit=$(git -C .. rev-parse HEAD)
    git_dirty=$([ -n "$(git -C .. status --porcelain 2>/dev/null)" ] && echo "true" || echo "false")
  else
    git_commit="unknown"; git_dirty="unknown"
  fi
  cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
  cpu_count=$(nproc 2>/dev/null || echo "unknown")
  total_mem_kb=$(grep -m1 "MemTotal" /proc/meminfo 2>/dev/null | grep -o '[0-9]*' || echo "unknown")

  # Records each service's cpuset as the resolved compose config declares it;
  # python-service's is the control value, since the cpuset arm sweeps others at runtime.
  local py_cpuset java_cpuset k6_cpuset
  py_cpuset=$(compose_service_value "python-service" cpuset)
  java_cpuset="$JAVA_CPUSET"
  k6_cpuset="$K6_CPUSET"

  # Empty when a service is missing from the resolved config, its cpuset key was renamed,
  # or the compose file failed to resolve; recording "unknown" for a running service
  # would hide that.
  [ -z "$py_cpuset" ] && abort_suite "[metadata]" "the compose config resolved no cpuset for python-service."
  [ -z "$java_cpuset" ] && abort_suite "[metadata]" "the compose config resolved no cpuset for transaction-service."
  [ -z "$k6_cpuset" ] && abort_suite "[metadata]" "the compose config resolved no cpuset for k6."

  local py_cores java_cores k6_cores total_pinned_cores
  py_cores=$(count_cpuset_cores "${py_cpuset:-}")
  java_cores=$(count_cpuset_cores "${java_cpuset:-}")
  k6_cores=$(count_cpuset_cores "${k6_cpuset:-}")
  total_pinned_cores=$((py_cores + java_cores + k6_cores))

  # The Java and k6 cpusets are fixed for the whole ablation, so they are checked once
  # here; python-service's varies per cell and is checked alongside each cell's restart.
  verify_service_cpuset "startup" "transaction-service" "$JAVA_CPUSET" "$JAVA_QUOTA"
  verify_service_cpuset "startup" "k6" "$K6_CPUSET" "$K6_QUOTA"

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "${timestamp}",
  "wsl2_detected": "${IS_WSL2}",
  "git_commit": "${git_commit}",
  "git_dirty": "${git_dirty}",
  "cpu_model": "${cpu_model}",
  "cpu_count": "${cpu_count}",
  "total_mem_kb": "${total_mem_kb}",
  "host_provenance": $(host_provenance_json),
  "jvm_pinned_options": "$(jvm_pinned_options)",
  "cores_used_by_suite": {
    "python_service_cpuset": "${py_cpuset:-unknown}",
    "python_service_cores": ${py_cores},
    "transaction_service_cpuset": "${java_cpuset:-unknown}",
    "transaction_service_cores": ${java_cores},
    "k6_cpuset": "${k6_cpuset:-unknown}",
    "k6_cores": ${k6_cores},
    "total_pinned_cores": ${total_pinned_cores},
    "host_cores_available": "${cpu_count}",
    "note": "python_service_cpuset reflects the docker-compose.yml control value; the cpuset arm sweeps other values at runtime"
  },
  "ablation_config": {
    "target": "${ABLATION_TARGET}",
    "vus": ${ABLATION_VUS},
    "iterations_per_vu": ${ITERATIONS_PER_VU},
    "iterations_per_vu_note": "fallback only -- actual value is calibrated per cell against calib_target_duration_s, see ablation_calib_* files",
    "calib_iter_per_vu": ${ABLATION_CALIB_ITER_PER_VU},
    "calib_target_duration_s": ${ABLATION_CALIB_TARGET_DURATION_S},
    "calib_scope": "measured once per (arm, value) in a dedicated pass before the reps; every rep runs that count",
    "reps": ${REPS_ABLATION},
    "anyio_default_tokens": ${ANYIO_DEFAULT_TOKENS},
    "control_values": {
      "thread_limiter": "${ANYIO_DEFAULT_TOKENS}",
      "cpuset": "${CONTROL_CPUSET}",
      "workers": "${CONTROL_WORKERS}"
    },
    "cells": [$(printf '"%s",' "${CELLS[@]}" | sed 's/,$//')],
    "warmup_gate": {
      "chunk_duration_s": ${WARMUP_CHUNK_DURATION_S},
      "max_chunks": ${MAX_WARMUP_CHUNKS},
      "base_window": ${WARMUP_WINDOW},
      "min_window_span_s": ${WARMUP_WINDOW_MIN_S},
      "tail_tolerance_pct": ${WARMUP_TAIL_TOLERANCE_PCT},
      "tail_abs_floor_ms": ${WARMUP_TAIL_ABS_FLOOR_MS}
    },
    "thermal": {
      "warn_c": ${THERMAL_WARN_C},
      "crit_c": ${THERMAL_CRIT_C},
      "cooldown_s": ${THERMAL_COOLDOWN_S},
      "max_cooldowns": ${MAX_THERMAL_COOLDOWNS}
    }
  }
}
EOF
  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} (pinned: ${total_pinned_cores}) git=${git_commit:0:12} wsl2=${IS_WSL2}"
  echo "  [metadata] $(host_provenance_line)"
}

# Reads one scalar field of a service out of the resolved compose configuration, so every
# check compares against the same source the containers are started from.
compose_service_value() {
  docker compose -f "$COMPOSE_FILE" --profile loadgen config 2>/dev/null \
    | awk -v svc="  ${1}:" -v key="${2}:" '
        $0 == svc { in_svc = 1; next }
        in_svc && /^  [a-zA-Z0-9_-]+:$/ { in_svc = 0 }
        in_svc && $1 == key { sub(/^ +[a-zA-Z0-9_-]+: */, ""); gsub(/"/, ""); print; exit }
      '
}

abort_suite() {
  local label="$1"; shift
  # >&2 on every line: some callers (e.g. jvm_container()) run inside a caller's
  # $( ), which would otherwise capture tee's stdout copy into that caller's
  # variable instead of letting it reach the console.
  echo "" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] ${label}: $*" | tee -a "$FAILURES_LOG" >&2
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

count_cpuset_cores() {
  local cpuset="$1" total=0 part lo hi
  IFS=',' read -ra _parts <<< "$cpuset"
  for part in "${_parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"; hi="${part#*-}"
      total=$(( total + (hi - lo + 1) ))
    elif [ -n "$part" ]; then
      total=$(( total + 1 ))
    fi
  done
  echo "$total"
}

read_live_cpuset() {
  docker exec "$1" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}

expand_cpuset() {
  local part lo hi i
  IFS=',' read -ra _parts <<< "$1"
  for part in "${_parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"; hi="${part#*-}"
      for ((i = lo; i <= hi; i++)); do echo "$i"; done
    elif [ -n "$part" ]; then
      echo "$part"
    fi
  done
}

# Lowest-numbered member of a logical CPU's SMT sibling list -- a stable key for
# the physical core behind it.
core_key_of_cpu() {
  local siblings="/sys/devices/system/cpu/cpu${1}/topology/thread_siblings_list"
  [ -r "$siblings" ] || return 0
  sed 's/[,-].*//' "$siblings" | tr -d ' \n'
}

core_keys_of_cpuset() {
  local cpu key
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    key=$(core_key_of_cpu "$cpu")
    # Plain `if`, not `[ -n ... ] && echo`: a false test as the loop's last command would
    # make the while-loop exit 1, which pipefail turns into a set -e abort.
    if [ -n "$key" ]; then echo "$key"; fi
  done < <(expand_cpuset "$1") | sort -un | paste -sd, -
}

# Counts logical CPUs in a cpuset whose physical core cannot be resolved. Dropping one
# would shrink the set compared for overlap, so an unresolved CPU aborts instead.
unresolved_cpus_in_cpuset() {
  local cpu n=0
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    if [ -z "$(core_key_of_cpu "$cpu")" ]; then n=$((n + 1)); fi
  done < <(expand_cpuset "$1")
  echo "$n"
}

# Rejects a cell whose python-service cpuset shares a physical core with Java or k6.
# Re-run per cell because the cpuset arm changes python-service's placement on every one.
verify_smt_isolation() {
  local label="$1" py_cpuset="$2"

  if [ ! -r /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]; then
    echo "  [smt] ${label}: WARNING -- SMT topology not exposed (common under WSL2);" \
         "physical-core disjointness is UNVERIFIED for this cell."
    echo "smt_check label=${label} status=unverifiable reason=topology_not_exposed" >> "$CPU_PIN_LOG"
    return 0
  fi

  local py_keys java_keys k6_keys shared
  py_keys=$(core_keys_of_cpuset "$py_cpuset")
  java_keys=$(core_keys_of_cpuset "$JAVA_CPUSET")
  k6_keys=$(core_keys_of_cpuset "$K6_CPUSET")

  local py_unres java_unres k6_unres
  py_unres=$(unresolved_cpus_in_cpuset "$py_cpuset")
  java_unres=$(unresolved_cpus_in_cpuset "$JAVA_CPUSET")
  k6_unres=$(unresolved_cpus_in_cpuset "$K6_CPUSET")
  if [ "$py_unres" -gt 0 ] || [ "$java_unres" -gt 0 ] || [ "$k6_unres" -gt 0 ]; then
    abort_suite "[smt] ${label}" "could not resolve a physical core for every pinned CPU" \
      "(unresolved: python=${py_unres} java=${java_unres} k6=${k6_unres}). Those CPUs would be dropped" \
      "from the overlap comparison, which could report isolation that does not hold."
  fi
  if [ -z "$py_keys" ] || [ -z "$java_keys" ] || [ -z "$k6_keys" ]; then
    abort_suite "[smt] ${label}" "at least one cpuset resolved to no physical cores at all" \
      "(python=${py_keys:-EMPTY} java=${java_keys:-EMPTY} k6=${k6_keys:-EMPTY}). An empty cpuset means" \
      "the configuration was never read, not that the services are disjoint."
  fi

  echo "  [smt] ${label}: physical cores python(${py_keys:-EMPTY}) java(${java_keys:-EMPTY}) k6(${k6_keys:-EMPTY})"
  echo "smt_check label=${label} python_cores=${py_keys:-EMPTY} java_cores=${java_keys:-EMPTY} k6_cores=${k6_keys:-EMPTY}" \
    >> "$CPU_PIN_LOG"

  shared=$(comm -12 \
    <(tr ',' '\n' <<< "$py_keys" | sort -u) \
    <(cat <(tr ',' '\n' <<< "$java_keys") <(tr ',' '\n' <<< "$k6_keys") | sort -u) | paste -sd, -)

  if [ -n "$shared" ]; then
    abort_suite "[smt] ${label}" "python-service's cpuset (${py_cpuset}) shares physical core(s) ${shared}" \
      "with transaction-service (${JAVA_CPUSET}) and/or k6 (${K6_CPUSET}) via SMT siblings. The cpuset" \
      "arm would then vary contention rather than core count, so its result would be uninterpretable." \
      "Pick cpuset values whose thread_siblings_list entries are disjoint from ${JAVA_CPUSET} and ${K6_CPUSET}" \
      "(inspect with: cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list)."
  fi
}

# python-service's cpuset varies per cell, so this compares live against requested
# only: whether the cgroup driver honored what this cell asked for.
verify_cpu_pinning() {
  local label="$1"
  local py_container java_container
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")

  if [ -z "$py_container" ] || [ -z "$java_container" ]; then
    abort_suite "[cpu-pin] ${label}" "could not resolve container IDs -- cannot verify pinning at all."
  fi

  local py_requested java_requested py_live java_live
  py_requested=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$py_container" 2>/dev/null || echo "")
  java_requested=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$java_container" 2>/dev/null || echo "")
  py_live=$(read_live_cpuset "$py_container")
  java_live=$(read_live_cpuset "$java_container")

  echo "  [cpu-pin] ${label}: python-service requested(${py_requested:-EMPTY}) live(${py_live:-EMPTY}) |" \
       "transaction-service requested(${java_requested:-EMPTY}) live(${java_live:-EMPTY})"
  echo "cpu_pin_check label=${label} python_requested=${py_requested:-EMPTY} python_live=${py_live:-EMPTY}" \
       "java_requested=${java_requested:-EMPTY} java_live=${java_live:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ -z "$py_live" ] || [ -z "$java_live" ]; then
    echo "  [cpu-pin] ${label}: WARN -- could not read live cgroup cpuset for python/java (WSL2/cgroup-v2 limitation); skipping live-vs-requested check."
    echo "cpu_pin_check label=${label} python_live=UNREADABLE java_live=UNREADABLE result=WARN_SKIPPED" >> "$CPU_PIN_LOG"
  elif [ "$py_live" != "$py_requested" ] || [ "$java_live" != "$java_requested" ]; then
    abort_suite "[cpu-pin] ${label}" "live cgroup cpuset (python=${py_live} java=${java_live}) does not match" \
      "the requested cpuset (python=${py_requested} java=${java_requested}) -- pinning was not honored" \
      "on this Docker/cgroup driver version."
  fi

  # Same JVM effective-CPU-count cross-check as run-suite.sh: a cpuset match above
  # doesn't confirm the JVM itself sized its thread pools off the right core count.
  local java_cpus expected_java_cpus
  java_cpus=$(docker exec "$java_container" sh -c \
    'java -XshowSettings:system -version 2>&1 | grep -i "Effective CPU Count" | grep -o "[0-9]*"' \
    2>/dev/null || echo "")
  expected_java_cpus=$(count_cpuset_cores "$java_requested")
  echo "  [cpu-pin] ${label}: JVM-reported effective CPU count(${java_cpus:-EMPTY}), expected(${expected_java_cpus:-EMPTY} from requested cpuset ${java_requested:-EMPTY})"
  echo "cpu_pin_check label=${label} jvm_effective_cpu_count=${java_cpus:-EMPTY} expected_from_cpuset=${expected_java_cpus:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ -z "$java_cpus" ]; then
    abort_suite "[cpu-pin] ${label}" "could not read the JVM-reported Effective CPU Count -- Netty event-loop" \
      "sizing is unverifiable for this cell."
  elif [ -z "$expected_java_cpus" ] || [ "$expected_java_cpus" = "0" ]; then
    abort_suite "[cpu-pin] ${label}" "could not derive an expected core count from the requested cpuset" \
      "(${java_requested:-EMPTY}) -- cannot verify JVM core detection for this cell."
  elif [ "$java_cpus" != "$expected_java_cpus" ]; then
    abort_suite "[cpu-pin] ${label}" "JVM reports ${java_cpus} effective CPUs, expected ${expected_java_cpus}" \
      "(derived from requested cpuset ${java_requested}). availableProcessors() sizes Reactor Netty's" \
      "event-loop pool (max(availableProcessors(), 4)), ForkJoinPool.commonPool, the G1 worker threads" \
      "and the JIT compiler threads -- all of them would be sized off the wrong core count for this cell."
  fi

  # K6_CPUSET is resolved once from the compose config and fixed for the whole
  # ablation (unlike python-service's), so it is this check's expected value.
  # `docker compose run --rm` can hang on cleanup of the ephemeral container; timeout
  # bounds it, and -k 10 sends SIGKILL if SIGTERM doesn't land.
  local k6_live k6_rc
  set +e
  k6_live=$(timeout -k 10 30 docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T --entrypoint sh k6 \
    -c 'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null)
  k6_rc=$?
  set -e
  echo "  [cpu-pin] ${label}: k6 live(${k6_live:-EMPTY}) expected(${K6_CPUSET})"
  echo "cpu_pin_check label=${label} k6_live=${k6_live:-EMPTY} k6_expected=${K6_CPUSET}" >> "$CPU_PIN_LOG"
  if [ "$k6_rc" -eq 124 ]; then
    echo "  [cpu-pin] ${label}: WARN -- k6 cpuset read timed out after 30s and was killed;" \
      "skipping k6 pin check for this cell. Not an environment limitation -- check" \
      "'docker compose version' if this recurs."
    echo "cpu_pin_check label=${label} k6_live=TIMEOUT k6_expected=${K6_CPUSET} result=WARN_SKIPPED_TIMEOUT" >> "$CPU_PIN_LOG"
  elif [ -z "$k6_live" ]; then
    echo "  [cpu-pin] ${label}: WARN -- could not read k6 cgroup cpuset (WSL2/cgroup-v2 limitation); skipping k6 pin check."
    echo "cpu_pin_check label=${label} k6_live=UNREADABLE k6_expected=${K6_CPUSET} result=WARN_SKIPPED" >> "$CPU_PIN_LOG"
  elif [ "$k6_live" != "$K6_CPUSET" ]; then
    abort_suite "[cpu-pin] ${label}" "k6's live cgroup cpuset (${k6_live}) does not match the requested" \
      "cpuset (${K6_CPUSET}) -- k6 core isolation was not honored on this Docker/cgroup driver version."
  fi

  echo "  [cpu-pin] ${label}: OK -- pinning verified, proceeding."
}

verify_tiers_and_limiter() {
  local label="$1" expected_tokens="$2"
  local health_json loaded_tiers all_verified live_tokens thread_env
  health_json=$(curl -s http://localhost:8000/health 2>/dev/null || echo "")
  [ -z "$health_json" ] && abort_suite "[health] ${label}" "could not reach python-service's /health."

  loaded_tiers=$(echo "$health_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(",".join(sorted((str(t) for t in d.get("loadedTiers", [])), key=int)))
except Exception:
    print("")
')
  all_verified=$(echo "$health_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("nJobsVerified", {})
    # Requires real booleans: all({}.values()) is True for an empty mapping, and a
    # truthy non-bool (e.g. "false") would pass too.
    print("true" if isinstance(v, dict) and v and all(x is True for x in v.values()) else "false")
except Exception:
    print("false")
')
  live_tokens=$(echo "$health_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("threadLimiterTokens", ""))
except Exception:
    print("")
')

  thread_env=$(echo "$health_json" | python3 -c '
import json, sys
try:
    env = json.load(sys.stdin).get("numericThreadEnv", {})
    print(",".join(f"{k}={v}" for k, v in sorted(env.items())))
except Exception:
    print("")
')

  echo "  [health] ${label}: tiers(${loaded_tiers:-EMPTY}) n_jobs_verified(${all_verified}) thread_limiter_tokens(${live_tokens:-EMPTY} expected ${expected_tokens})"
  echo "cpu_pin_check label=${label} tiers_loaded=${loaded_tiers:-EMPTY} tiers_expected=${EXPECTED_TIERS} n_jobs_verified=${all_verified} numeric_thread_env=${thread_env:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ "$loaded_tiers" != "$EXPECTED_TIERS" ]; then
    abort_suite "[health] ${label}" "loadedTiers (${loaded_tiers:-EMPTY}) != expected (${EXPECTED_TIERS})."
  elif [ "$all_verified" != "true" ]; then
    abort_suite "[health] ${label}" "nJobsVerified reports at least one tier without n_jobs=1."
  elif [ "$live_tokens" != "$expected_tokens" ]; then
    abort_suite "[health] ${label}" "threadLimiterTokens (${live_tokens:-EMPTY}) != expected (${expected_tokens}) -- override did not take effect."
  fi

  # n_jobs=1 alone does not constrain the OpenMP/BLAS layer beneath it, so all four
  # variables are asserted. The match is comma-delimited: a bare *OMP_NUM_THREADS=1*
  # substring would also accept 10, 100 or 1024.
  local tvar
  for tvar in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS NUMEXPR_NUM_THREADS; do
    case ",${thread_env}," in
      *",${tvar}=1,"*) ;;
      *) abort_suite "[health] ${label}" "${tvar} is not pinned to exactly 1 (${thread_env:-EMPTY})" \
           "-- numeric libraries may spawn threads outside the measured cpuset." ;;
    esac
  done
}

# Polls until each of $workers workers has answered /health, so n_jobs is confirmed on
# every one; worker count is itself the manipulated variable in two of the arms.
# $workers is the cell loop's variable, which is deliberately not declared local there.
verify_tiers_runtime() {
  local label="$1"
  local expected_workers="${workers:-1}"
  local seen_pids="" runtime_state sample pid
  local attempts=$((expected_workers * 10))

  for _ in $(seq 1 "$attempts"); do
    sample=$(curl -s http://localhost:8000/health 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    verified = d.get("nJobsRuntimeVerified", {})
except Exception:
    print("unreadable ")
else:
    # Requires an explicit key: an absent key, empty mapping, or null would read as success.
    # A null tier has not served inference on this worker yet, so a worker with no true
    # tier has verified nothing and is not counted.
    if not isinstance(verified, dict) or not verified:
        print("unreadable", d.get("workerPid", ""))
    else:
        failed = [tier for tier, ok in verified.items() if ok is not True and ok is not None]
        exercised = any(ok is True for ok in verified.values())
        state = "failed:" + ",".join(failed) if failed else ("ok" if exercised else "unexercised")
        print(state, d.get("workerPid", ""))
') || sample="unreadable "
    runtime_state="${sample%% *}"
    pid="${sample##* }"

    if [ "$runtime_state" = "unreadable" ]; then
      abort_suite "[health] ${label}" "could not read nJobsRuntimeVerified from python-service's /health."
    elif [ "$runtime_state" = "unexercised" ]; then
      continue
    elif [ "$runtime_state" != "ok" ]; then
      abort_suite "[health] ${label}" "nJobsRuntimeVerified reports ${runtime_state} after serving inference" \
        "on worker ${pid:-unknown}."
    fi

    case " ${seen_pids} " in
      *" ${pid} "*) ;;
      *) seen_pids="${seen_pids}${pid} " ;;
    esac
    [ "$(echo "$seen_pids" | wc -w)" -ge "$expected_workers" ] && break
  done

  local n_seen
  n_seen=$(echo "$seen_pids" | wc -w)
  echo "  [health] ${label}: n_jobs_runtime ok on ${n_seen}/${expected_workers} worker(s) (pids: ${seen_pids% })"
  echo "cpu_pin_check label=${label} n_jobs_runtime=ok workers_checked=${n_seen} workers_expected=${expected_workers}" \
    >> "$CPU_PIN_LOG"

  if [ "$n_seen" -lt "$expected_workers" ]; then
    echo "  [health] ${label}: WARN -- only ${n_seen} of ${expected_workers} workers reported a tier" \
         "verified after serving inference across ${attempts} polls; the others are unverified for this cell." >&2
  fi
}

restart_stack() {
  local cpuset="$1" cpus="$2" workers="$3" tokens="$4"
  echo "  [restart] cpuset=${cpuset} cpus=${cpus} workers=${workers} thread_limiter_tokens=${tokens}"
  docker compose -f "$COMPOSE_FILE" down
  PYTHON_CPUSET="$cpuset" PYTHON_CPUS="$cpus" UVICORN_WORKERS="$workers" THREAD_LIMITER_TOKENS="$tokens" \
    docker compose -f "$COMPOSE_FILE" up -d --wait
}

wait_for_ready() {
  local url="http://localhost:8080/api/v1/transactions"
  for i in $(seq 1 60); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
      2>/dev/null) || status="000"
    [ "$status" = "200" ] && { echo "  [ready] after ${i} attempt(s)."; return 0; }
    sleep 2
  done
  # Routed through abort_suite so a readiness timeout reaches the failures log that
  # analyze-ablation.py gates on, rather than exiting with that log still clean.
  abort_suite "[ready]" "transaction-service did not respond 200 within 60 attempts" \
    "(last status ${status:-none}) -- the stack never became ready for this cell."
}

check_oom_killed() {
  local label="$1" py_container java_container py_oom java_oom
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  py_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$py_container" 2>/dev/null || echo "unknown")
  java_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$java_container" 2>/dev/null || echo "unknown")
  if [ "$py_oom" = "unknown" ] || [ "$java_oom" = "unknown" ]; then
    abort_suite "[oom]" "could not determine OOM-kill state (python=${py_oom} java=${java_oom})." \
      "A container that OOM-died and was removed also reports unknown, which is the case this" \
      "check exists to catch -- refusing to treat it as clean."
  fi
  if [ "$py_oom" = "true" ] || [ "$java_oom" = "true" ]; then
    abort_suite "[cell] ${label}" "OOM-killed: python=${py_oom} java=${java_oom}"
  fi
}

k6_run() {
  local script="$1"; shift
  local env_flags=()
  while [ "$1" != "--" ]; do env_flags+=("-e" "$1"); shift; done
  shift
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    "${env_flags[@]}" k6 run "/scripts/${script}" "$@"
}

# Filters a raw k6 JSON trail down to ABLATION_KEEP_METRICS and gzips it into
# RESULTS_DIR, then deletes the raw copy. Runs on the host, after the
# container that wrote the raw file has already exited.
# Usage: finalize_result <name.json>  -- name matches what --out json=
# pointed at under /results/raw/ (container path) / RAW_RESULTS_DIR (host path).
finalize_result() {
  local name="$1"
  python3 "${LIB_DIR}/k6_filter.py" finalize "${RAW_RESULTS_DIR}/${name}" "${RESULTS_DIR}/${name}.gz" "$ABLATION_KEEP_METRICS"
  rm -f "${RAW_RESULTS_DIR}/${name}"
}

# Filters a raw k6 JSON chunk down to ABLATION_KEEP_METRICS and appends it to a
# plain (uncompressed) file, so converge_warmup never accumulates raw chunks.
filter_chunk() {
  python3 "${LIB_DIR}/k6_filter.py" append "$1" "$2" "$ABLATION_KEEP_METRICS"
}

# Gzips an already-filtered file and deletes the plain copy.
gzip_only() {
  python3 "${LIB_DIR}/k6_filter.py" gzip "$1" "$2"
  rm -f "$1"
}

# Same convergence gate as run-suite.sh's converge_warmup(), kept identical to it
# (see that function's comment for the rationale): warm-up.js in duration-bounded
# chunks, lib/warmup_gate.py's criterion after each, stopping once ABLATION_TARGET
# has converged or after MAX_WARMUP_CHUNKS chunks.
WARMUP_CHUNK_DURATION_S=15
MAX_WARMUP_CHUNKS=4
WARMUP_WINDOW=500
WARMUP_WINDOW_MIN_S=3
WARMUP_TAIL_TOLERANCE_PCT=5.0
WARMUP_TAIL_ABS_FLOOR_MS=0.25
WARMUP_TABLE="table0_ablation_warmup_convergence_check"

converge_warmup() {
  local out_prefix="$1"; shift
  local -a base_args=("$@")

  # warm-up.js's own default when no WARMUP_TARGETS is passed.
  local arg expect="mock calibration 5 10 20 28"
  for arg in "${base_args[@]}"; do
    if [[ "$arg" == WARMUP_ITERATIONS_PER_TARGET=* ]]; then
      k6_run warm-up.js "${base_args[@]}" -- --out "json=/results/raw/${out_prefix}.json"
      finalize_result "${out_prefix}.json"
      return
    fi
    if [[ "$arg" == WARMUP_TARGETS=* ]]; then
      expect="${arg#WARMUP_TARGETS=}"
    fi
  done

  local combined="${RAW_RESULTS_DIR}/${out_prefix}_combined.json"
  : > "$combined"
  local chunk=0 converged="false"
  while [ "$chunk" -lt "$MAX_WARMUP_CHUNKS" ]; do
    chunk=$((chunk + 1))
    local chunk_name="${out_prefix}_chunk${chunk}.json"
    k6_run warm-up.js "${base_args[@]}" "WARMUP_DURATION_S=${WARMUP_CHUNK_DURATION_S}" -- \
      --out "json=/results/raw/${chunk_name}"
    filter_chunk "${RAW_RESULTS_DIR}/${chunk_name}" "$combined"
    rm -f "${RAW_RESULTS_DIR}/${chunk_name}"
    check_thermal_safety "${out_prefix} chunk${chunk}"

    # Checked after the last chunk too: that verdict is the state the measured
    # phase starts from, and the one table0 reports.
    converged=$(python3 "${LIB_DIR}/warmup_gate.py" "$combined" --expect "$expect" \
      --label "${out_prefix} chunk${chunk}" --window "$WARMUP_WINDOW" --min-span-s "$WARMUP_WINDOW_MIN_S" \
      --tol "$WARMUP_TAIL_TOLERANCE_PCT" --floor "$WARMUP_TAIL_ABS_FLOOR_MS")
    [ "$converged" = "true" ] && break
  done

  if [ "$converged" = "true" ]; then
    echo "  [warmup] ${out_prefix}: converged after ${chunk} chunk(s)."
  else
    echo "  [warmup] ${out_prefix}: did not converge within ${MAX_WARMUP_CHUNKS} chunk(s) " \
         "(~$((MAX_WARMUP_CHUNKS * WARMUP_CHUNK_DURATION_S))s/target) -- proceeding with " \
         "what was collected. ${WARMUP_TABLE} reports each target's verdict."
  fi
  check_thermal_safety "${out_prefix} pre-finalize"
  gzip_only "$combined" "${RESULTS_DIR}/${out_prefix}.json.gz"
}

# Measures this cell's real throughput at ABLATION_CALIB_ITER_PER_VU, then sets
# the global ABLATION_ITER_PER_VU to whatever hits ABLATION_CALIB_TARGET_DURATION_S
# at ABLATION_VUS. Runs after warm-up so the measurement isn't contaminated by cold
# start. phase=ablation-calib keeps this run out of analyze-ablation.py's
# phase=ablation filter, and the ablation_calib_ filename prefix keeps it out of
# CELL_FILE_RE's known-arm match.
calibrate_ablation_cell() {
  local arm="$1" value="$2"
  local raw_name="ablation_calib_${arm}_${value}.json"
  echo "  [calibrate] arm=${arm} value=${value}: measuring throughput at VUS=${ABLATION_VUS}..."
  k6_run run-target.js \
    TARGET="$ABLATION_TARGET" VUS="$ABLATION_VUS" ITERATIONS_PER_VU="$ABLATION_CALIB_ITER_PER_VU" \
    PHASE=ablation-calib REP=calib -- \
    --out "json=/results/raw/${raw_name}"
  finalize_result "$raw_name"

  local host_path="${RESULTS_DIR}/${raw_name}.gz"
  ABLATION_ITER_PER_VU=$(python3 - "$host_path" "$ABLATION_CALIB_TARGET_DURATION_S" "$ABLATION_VUS" <<'PYEOF'
import gzip, json, re, sys
from datetime import datetime

def parse_iso(ts):
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts)
    return datetime.fromisoformat(ts)

fp, target_s, vus = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
times = []
with gzip.open(fp, "rt") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("type") != "Point" or obj.get("metric") != "http_req_duration":
            continue
        tags = obj["data"].get("tags") or {}
        if tags.get("phase") != "ablation-calib":
            continue
        # A failed request still emits a phase=ablation-calib point; counting it would
        # derive the cell's iteration count from traffic that never reached the service.
        if tags.get("status") != "200":
            continue
        times.append(parse_iso(obj["data"]["time"]))
times.sort()
if len(times) < 2:
    sys.exit(f"calibration produced {len(times)} usable ablation-calib point(s); need at least 2")
duration = (times[-1] - times[0]).total_seconds()
if duration <= 0:
    sys.exit("calibration points all share one timestamp; cannot derive throughput")
# N completion timestamps bound N-1 inter-completion intervals, so the rate over that
# span is (N-1)/span -- same convention as analyze-results.py's _throughput_reqs_per_s.
# N/span overestimates by a factor of N/(N-1), negligible at real cell sizes but not
# the same quantity.
throughput = (len(times) - 1) / duration
target_total_requests = throughput * target_s
print(max(1, round(target_total_requests / vus)))
PYEOF
  )
  echo "  [calibrate] arm=${arm} value=${value}: ITERATIONS_PER_VU=${ABLATION_ITER_PER_VU}"
}

# Calibrates every cell once, on a stack prepared exactly like that cell's reps (restart
# at its configuration, pin checks, gated warm-up) that then runs no measured cell.
# Calibrating inside a rep would give that rep a load history the others lack, and
# calibrating in every rep would let each rep of a cell run a different workload.
calibrate_ablation_cells() {
  local cell arm value cpuset cpus workers tokens label
  echo "[*] Ablation calibration: each cell's throughput at VUS=${ABLATION_VUS}, measured once for every rep"
  for cell in "${CELLS[@]}"; do
    IFS=':' read -r arm value cpuset cpus workers tokens <<< "$cell"
    label="calibration arm=${arm} value=${value}"
    echo "  -> ${label}"
    record_env_sample "calibration_${arm}_${value}_start"
    verify_smt_isolation "$label" "$cpuset"
    verify_service_cpuset "$label" "python-service" "$cpuset" "$cpus"
    restart_stack "$cpuset" "$cpus" "$workers" "$tokens"
    wait_for_ready
    verify_cpu_pinning "$label"
    verify_jvm_flag_pins "$label"
    verify_tiers_and_limiter "$label" "$tokens"
    converge_warmup "ablation_calib_warmup_${arm}_${value}" "${WARMUP_ENV_ARGS[@]}" "REP=calib"
    verify_tiers_runtime "$label"
    verify_jvm_thread_pins "$label"
    sleep "$COOLDOWN_S"

    calibrate_ablation_cell "$arm" "$value"
    ABLATION_CALIB_CACHE[${arm}:${value}]="$ABLATION_ITER_PER_VU"
    echo "calibration arm=${arm} value=${value} iterations_per_vu=${ABLATION_ITER_PER_VU}" >> "$CALIB_LOG"
    check_thermal_safety "$label"
    record_env_sample "calibration_${arm}_${value}_end"
    sleep "$COOLDOWN_S"
  done
}

shuffled() { printf '%s\n' "$@" | shuf | tr '\n' ' '; }

# Java's and k6's placement never changes during the ablation. Read from the resolved
# compose configuration the containers start from, the same source run-suite.sh checks,
# so a .env override is verified rather than assumed.
JAVA_CPUSET=$(compose_service_value "transaction-service" cpuset)
JAVA_QUOTA=$(compose_service_value "transaction-service" cpus)
K6_CPUSET=$(compose_service_value "k6" cpuset)
K6_QUOTA=$(compose_service_value "k6" cpus)

capture_run_metadata
calibrate_ablation_cells

echo "[*] Ablation: ${#CELLS[@]} cells x ${REPS_ABLATION} reps, target=${ABLATION_TARGET} vus=${ABLATION_VUS}"
for rep in $(seq 1 "$REPS_ABLATION"); do
  echo "[*] --- Ablation repetition ${rep}/${REPS_ABLATION} ---"
  read -ra CELLS_THIS_REP <<< "$(shuffled "${CELLS[@]}")"
  echo "ablation rep=${rep} cell_order=${CELLS_THIS_REP[*]}" >> "$ORDER_LOG"

  for cell in "${CELLS_THIS_REP[@]}"; do
    IFS=':' read -r arm value cpuset cpus workers tokens <<< "$cell"
    label="arm=${arm} value=${value} rep=${rep}"
    echo "  -> ${label}"

    record_env_sample "${arm}_${value}_rep${rep}_start"
    verify_smt_isolation "$label" "$cpuset"
    verify_service_cpuset "$label" "python-service" "$cpuset" "$cpus"
    restart_stack "$cpuset" "$cpus" "$workers" "$tokens"
    wait_for_ready
    verify_cpu_pinning "$label"
    verify_jvm_flag_pins "$label"
    verify_tiers_and_limiter "$label" "$tokens"

    echo "  [warm-up] VUS=${ABLATION_VUS}..."
    warmup_name="ablation_warmup_${arm}_${value}_rep${rep}"
    converge_warmup "$warmup_name" "${WARMUP_ENV_ARGS[@]}" "REP=${rep}"
    verify_tiers_runtime "$label"
    verify_jvm_thread_pins "$label"
    sleep "$COOLDOWN_S"

    ABLATION_ITER_PER_VU="${ABLATION_CALIB_CACHE[${arm}:${value}]}"

    cell_name="ablation_${arm}_${value}_rep${rep}.json"
    record_cell_thermal start "${cell_name%.json}"
    if ! k6_run run-target.js \
      TARGET="$ABLATION_TARGET" VUS="$ABLATION_VUS" ITERATIONS_PER_VU="$ABLATION_ITER_PER_VU" \
      PHASE=ablation REP="$rep" ARM="$arm" ARM_VALUE="$value" -- \
      --out "json=/results/raw/${cell_name}"
    then
      abort_suite "[cell] ${label}" "k6 exited non-zero."
    fi
    record_cell_thermal end "${cell_name%.json}"
    check_oom_killed "$label"
    check_thermal_safety "$label"
    finalize_result "$cell_name"
    record_env_sample "${arm}_${value}_rep${rep}_end"
    sleep "$COOLDOWN_S"
  done
done

docker compose -f "$COMPOSE_FILE" down
# Guards against an empty run: the completion banner would otherwise report success after
# executing no cells at all. ablation_calib_* and ablation_warmup_* also match the cell
# pattern, so they are excluded to count measured cells only.
_n_cells=$(find "$RESULTS_DIR" -maxdepth 1 -name 'ablation_*_rep*.json.gz' \
  ! -name 'ablation_calib_*' ! -name 'ablation_warmup_*' 2>/dev/null | wc -l)
if [ "$_n_cells" -eq 0 ]; then
  abort_suite "[ablation]" "no ablation cells were executed -- check ABLATION_CELLS_OVERRIDE and" \
    "REPS_ABLATION_OVERRIDE. Not reporting this run as successful."
fi

echo "[+] Ablation complete. Raw results in ${RESULTS_DIR}/ablation_*.json.gz"
echo "    SMT topology and pinning checks logged to ${CPU_PIN_LOG}"
echo "    Per-cell governor/frequency/temperature and thermal samples logged to ${ENV_TRACE_LOG}"
echo "    The iteration count every cell ran with logged to ${CALIB_LOG}"
echo "    Run: ../analysis/venv/bin/python3 ../analysis/analyze-ablation.py"