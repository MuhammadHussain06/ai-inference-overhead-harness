#!/usr/bin/env bash
set -euo pipefail

# Detaches stdin: a backgrounded docker compose invocation that inherits the
# terminal's stdin gets stopped by SIGTTIN the moment it tries to read it.
exec < /dev/null

# Orchestrates clean-slate stack restarts, randomized execution order, system provenance logging,
# and verification of CPU pinning, thread caps (n_jobs, BLAS/OpenMP), and CPU governor frequencies.

# Anchor execution directory to the script's location for path stability.
cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

# Preflight: fail fast before any containers are touched.
# k6 runs containerized (see the `k6` service in docker-compose.yml),
# pinned to its own cpuset, separate from the services under test.
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

# Host-state provenance for run_metadata.json, the JVM collector/thread-pool guards, the
# topology checks that decide whether this host's cpusets mean what they say, and the
# thermal guard and telemetry.
. lib/host-provenance.sh
. lib/jvm-pins.sh
. lib/topology.sh
. lib/thermal.sh

# Reading topology or temperatures from anywhere but the live tree would verify core
# placement, or guard heat, on a host that is not the one running the containers.
for _sysfs_var in TOPO_SYSFS_ROOT THERMAL_SYSFS_ROOT; do
  if [ "${!_sysfs_var:-/sys}" != "/sys" ]; then
    echo "[!] ${_sysfs_var} is set to '${!_sysfs_var}'. The suite reads the live host only;" >&2
    echo "    unset it before running." >&2
    exit 1
  fi
done

# On WSL2 the cgroup cpuset checks pass but Hyper-V host core migration is
# unobservable, so pinning cannot actually be confirmed. Non-blocking; recorded
# in run_metadata.json.
IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- physical-core pinning is not guaranteed even when" >&2
  echo "    verify_cpu_pinning() reports OK (see README Limitations). Recorded" >&2
  echo "    in run_metadata.json for this run." >&2
fi

# Set by verify_smt_isolation() during metadata capture; recorded in run_metadata.json.
SMT_TOPOLOGY_STATUS="not checked"

# Both overridable so the fault-injection suite can run the harness against a patched
# configuration without writing into a real dataset.
COMPOSE_FILE="${COMPOSE_FILE_OVERRIDE:-../docker-compose.yml}"
RESULTS_DIR="${RESULTS_DIR_OVERRIDE:-../results}"
# k6 writes its full, unfiltered trail here (container-visible as /results/raw);
# finalize_result() filters + gzips each file into RESULTS_DIR and deletes the
# raw copy right after, so this stays near-empty except mid-cell.
RAW_RESULTS_DIR="${RESULTS_DIR}/raw"
rm -rf "$RAW_RESULTS_DIR"
mkdir -p "$RESULTS_DIR" "$RESULTS_DIR/gc-logs" "$RAW_RESULTS_DIR"

# Moves a prior run's cell logs, JSON metrics and GC output into a timestamped
# subdirectory. The analysis scripts glob RESULTS_DIR non-recursively, so anything
# left at its top level would be read as part of this run. ablation_* files belong to
# run-ablation.sh, which shares RESULTS_DIR and archives its own.
if [ -n "$(find "$RESULTS_DIR" -maxdepth 1 \( -name '*.json' -o -name '*.json.gz' -o -name 'run_order_log.txt' \) \
      ! -name 'ablation_*' -print -quit)" ]; then
  ARCHIVE_DIR="${RESULTS_DIR}/archive/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$ARCHIVE_DIR"
  for _pattern in '*.json' '*.json.gz' '*_log.txt'; do
    find "$RESULTS_DIR" -maxdepth 1 -name "$_pattern" ! -name 'ablation_*' -exec mv {} "$ARCHIVE_DIR/" \;
  done
  if [ -d "${RESULTS_DIR}/gc-logs" ] && [ -n "$(ls -A "${RESULTS_DIR}/gc-logs" 2>/dev/null)" ]; then
    mv "${RESULTS_DIR}/gc-logs" "${ARCHIVE_DIR}/gc-logs"
    mkdir -p "${RESULTS_DIR}/gc-logs"
  fi
  echo "[*] Archives previous run's results to ${ARCHIVE_DIR}"
fi

ORDER_LOG="${RESULTS_DIR}/run_order_log.txt"
: > "$ORDER_LOG"   # truncate/create fresh each suite run
METADATA_FILE="${RESULTS_DIR}/run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/run_failures_log.txt"
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

: > "$FAILURES_LOG"   # truncate/create fresh each suite run
CPU_PIN_LOG="${RESULTS_DIR}/cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"   # truncate/create fresh each suite run
# Governor, frequency, temperature and throttle counters at both ends of every rep,
# temperature and throttle counters at both edges of every measured cell, and every
# thermal check with the time it paused for (see lib/thermal.sh).
ENV_TRACE_LOG="${RESULTS_DIR}/env_trace_log.txt"
: > "$ENV_TRACE_LOG"   # truncate/create fresh each suite run
# The iteration counts every scan rep runs each calibrated target with.
CALIB_LOG="${RESULTS_DIR}/calibration_log.txt"
: > "$CALIB_LOG"

TARGETS=(${TARGETS_OVERRIDE:-mock calibration 5 10 20 28})
CONCURRENCY_LEVELS=(${CONCURRENCY_OVERRIDE:-1 2 4 8 16 32 64})
# python-service always loads every tier in docker-compose.yml's FEATURE_TIERS,
# regardless of which subset of targets this invocation exercises -- keep in
# sync with docker-compose.yml's FEATURE_TIERS if that value ever changes.
EXPECTED_TIERS="5,10,20,28"
# Keep in sync with docker-compose.yml's THREAD_LIMITER_TOKENS default.
EXPECTED_THREAD_LIMITER_TOKENS="40"
# Derived from CONCURRENCY_LEVELS; used by E2's max-VUS warm-up pass below.
MAX_VUS=0
for _lvl in "${CONCURRENCY_LEVELS[@]}"; do
  if [ "$_lvl" -gt "$MAX_VUS" ]; then MAX_VUS="$_lvl"; fi
done
BASELINE_ITERATIONS="${BASELINE_ITERATIONS_OVERRIDE:-500}"
# Flat fallback for the concurrency levels outside CALIB_AFFECTED_LEVELS (1/2/4
# by default), where too few VUs are in flight for the end-of-cell taper to
# matter. The rest get a per-target calibrated value -- see calibrate_target().
# Matches BASELINE_ITERATIONS rather than a smaller value: these levels are the
# same per-target sample size baseline already runs at VUS=1, keeping their
# between-run noise in the range baseline's own reproducibility already shows
# is acceptable, at a cost of well under a minute added to the whole run.
SCAN_ITERATIONS_PER_VU="${SCAN_ITERATIONS_PER_VU_OVERRIDE:-500}"

# per-vu-iterations runs each VU to a fixed iteration count independent of the
# others, so VUs finish at slightly different wall-clock times and effective
# concurrency tapers off near the end of a cell. That taper's absolute duration
# is roughly fixed regardless of cell length, so a short cell spends a larger
# fraction of itself in it. Retargeting CALIB_AFFECTED_LEVELS' iteration counts
# to a fixed wall-clock duration keeps the taper a small tail instead of most of
# the cell. Each target is calibrated once, in a pass of its own before the scan
# reps (see calibrate_scan_targets()), and every rep runs those counts: each rep of a
# cell then runs the same workload after the same load history, and rep-to-rep
# throughput drift only moves a cell's duration around its target, never what is
# measured in it.
CALIB_VUS=16
CALIB_ITER_PER_VU=2000
CALIB_TARGET_DURATION_S=60
CALIB_AFFECTED_LEVELS="8 16 32 64"
declare -A CALIB_ITERATIONS_PER_VU
# "<target>:<vus>" -> iterations per VU, filled by calibrate_scan_targets().
declare -A CALIB_CACHE

# The metrics the analysis tables and figures read. k6's raw trail carries
# roughly twice this many; dropping the rest at write time roughly halves both
# on-disk size and analyze-results.py's peak memory. java_execution_time_ms is kept
# so http_req_duration minus the Java-side total stays computable from the dataset.
KEEP_METRICS="http_req_duration,http_req_blocked,dropped_iterations,request_http_error,request_timeout_error,python_parsing_time_ms,python_thread_dispatch_time_ms,python_computation_time_ms,python_dataframe_construction_time_ms,python_model_inference_time_ms,python_compute_stall_time_ms,python_serialization_time_ms,python_total_time_ms,java_estimated_bridge_overhead_ms,java_execution_time_ms"
# Unset by default, which leaves warm-up.js on its duration-based path so
# converge_warmup can drive it in chunks. Setting it (e.g. for the smoke test)
# makes converge_warmup fall back to a single fixed-iteration pass, so a
# reduced-scale run is not dwarfed by its own warm-up. Applies to the baseline
# and default-VUS scan passes only -- the maxvus pass runs at a much higher VUS
# and needs its own iteration/duration budget to converge, so it has separate
# overrides below.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"
WARMUP_MAX_DURATION_S_OVERRIDE="${WARMUP_MAX_DURATION_S_OVERRIDE:-}"

# ITERATIONS_PER_TARGET is a total budget divided by VUS, so the maxvus pass
# gets far fewer iterations per VU out of the same value than the VUS=5 passes
# do. A single shared override would have to be raised until maxvus converges,
# which inflates the other two passes' raw JSON (one line per metric per
# request) and analyze-results.py's memory for no benefit. Falls back to the
# shared override above when unset.
WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE:-$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}"
WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE="${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE:-$WARMUP_MAX_DURATION_S_OVERRIDE}"

# Warm-up env args for the baseline and default-VUS scan passes.
# WARMUP_TARGETS scopes warm-up to this run's actual TARGETS.
WARMUP_ENV_ARGS=("WARMUP_TARGETS=${TARGETS[*]}")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAX_DURATION_S_OVERRIDE}")
fi

# Separate env args for the maxvus pass -- own iteration/duration budget,
# same WARMUP_TARGETS scoping.
WARMUP_MAXVUS_ENV_ARGS=("WARMUP_TARGETS=${TARGETS[*]}")
if [ -n "$WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE}")
fi
COOLDOWN_S=10
# ACPI/DPTF thermal negotiation does not complete on every platform, which can
# leave the OS blind to platform thermal policy. check_thermal_safety()
# (lib/thermal.sh) reads /sys/class/thermal directly rather than trusting a
# userspace daemon, so a long pinned-core run pauses or aborts instead of
# hard-hanging.
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
# Rounds beyond MAX_THERMAL_COOLDOWNS are only granted while still cooling
# (check_thermal_safety), so this bounds the worst case rather than setting the
# common one.
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"
# n=7 vs 7 puts the minimum achievable two-sided Mann-Whitney p-value at
# 2/C(14,7) = 0.00058, which still clears alpha=0.05 after Holm correction
# across the five adjacent-tier comparisons (0.00058 x 5 = 0.0029). n=5 vs 5
# reaches only 0.0079, or 0.0397 corrected -- significant, but with no margin
# for a single noisy rep. Overriding below 7 (e.g. for a smoke test) is fine
# for a pipeline check, not for a rep count you intend to analyze for real.
REPS_BASELINE="${REPS_BASELINE_OVERRIDE:-7}"
REPS_SCAN="${REPS_SCAN_OVERRIDE:-7}"

# Command substitution in a for-list is not an errexit context, so integer overrides must
# be validated explicitly before use.
for _intvar in REPS_BASELINE REPS_SCAN BASELINE_ITERATIONS SCAN_ITERATIONS_PER_VU \
  THERMAL_WARN_C THERMAL_CRIT_C THERMAL_COOLDOWN_S MAX_THERMAL_COOLDOWNS THERMAL_MAX_COOLDOWNS_EXTENDED; do
  if ! [[ "${!_intvar}" =~ ^[0-9]+$ ]] || [ "${!_intvar}" -lt 1 ]; then
    echo "[!] ${_intvar} must be a positive integer, got '${!_intvar}'." >&2
    exit 1
  fi
done
if [ "$THERMAL_MAX_COOLDOWNS_EXTENDED" -lt "$MAX_THERMAL_COOLDOWNS" ]; then
  echo "[!] THERMAL_MAX_COOLDOWNS_EXTENDED (${THERMAL_MAX_COOLDOWNS_EXTENDED}) must be >=" \
       "MAX_THERMAL_COOLDOWNS (${MAX_THERMAL_COOLDOWNS})." >&2
  exit 1
fi
if [ "${#TARGETS[@]}" -eq 0 ] || [ "${#CONCURRENCY_LEVELS[@]}" -eq 0 ]; then
  echo "[!] TARGETS and CONCURRENCY_LEVELS must each be non-empty (check TARGETS_OVERRIDE / CONCURRENCY_OVERRIDE)." >&2
  exit 1
fi
for _lvl in "${CONCURRENCY_LEVELS[@]}"; do
  if ! [[ "$_lvl" =~ ^[0-9]+$ ]] || [ "$_lvl" -lt 1 ]; then
    echo "[!] CONCURRENCY_OVERRIDE must contain only positive integers, got '${_lvl}'." >&2
    exit 1
  fi
done

# Sized off this run's own peak VUS so the Java outbound pool can never become
# the bottleneck being measured. Consumed by docker-compose.yml.
export PYTHON_SERVICE_MAX_CONNECTIONS=$((MAX_VUS * 2))


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

capture_run_metadata() {
  echo "[*] Capturing run metadata to ${METADATA_FILE}..."

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local host_uname
  host_uname=$(uname -a 2>/dev/null || echo "unknown")

  local docker_version
  docker_version=$(docker --version 2>/dev/null || echo "unknown")

  local compose_version
  compose_version=$(docker compose version 2>/dev/null || echo "unknown")

  # The load generator is the one image pulled by tag rather than built from this
  # tree, so its resolved digest is what makes the run reproducible.
  local k6_image k6_digest
  k6_image=$(docker compose -f "$COMPOSE_FILE" --profile loadgen config --images 2>/dev/null | grep -i 'k6' | head -1 || true)
  k6_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${k6_image:-grafana/k6}" 2>/dev/null \
    || echo "unknown (image not pulled yet)")

  local git_commit git_dirty
  if command -v git >/dev/null 2>&1 && git -C .. rev-parse HEAD >/dev/null 2>&1; then
    git_commit=$(git -C .. rev-parse HEAD)
    if [ -n "$(git -C .. status --porcelain 2>/dev/null)" ]; then
      git_dirty="true"
    else
      git_dirty="false"
    fi
  else
    git_commit="unknown"
    git_dirty="unknown"
  fi

  local cpu_model cpu_count
  if [ -r /proc/cpuinfo ]; then
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | sed 's/.*: //' || echo "unknown")
    cpu_count=$(nproc 2>/dev/null || echo "unknown")
  else
    cpu_model="unknown"
    cpu_count="unknown"
  fi

  local total_mem_kb
  if [ -r /proc/meminfo ]; then
    total_mem_kb=$(grep -m1 "MemTotal" /proc/meminfo | grep -o '[0-9]*' || echo "unknown")
  else
    total_mem_kb="unknown"
  fi

  # Opening snapshot only; record_env_sample() traces both ends of every rep
  # to env_trace_log.txt, which is what catches mid-suite throttling.
  local cpu_governor cpu_freq_khz
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    cpu_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
  else
    cpu_governor="unknown (cpufreq not exposed on this host)"
  fi
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    cpu_freq_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "unknown")
  else
    cpu_freq_khz="unknown (cpufreq not exposed on this host)"
  fi

  # Escape backslashes/quotes in free-text fields before embedding in JSON.
  json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

  # Resolved config, not the literal defaults: compose expands the PYTHON_CPUSET,
  # JAVA_CPUSET and K6_CPUSET overrides. Summed to check the cores pinned across
  # the stack against cpu_count above.
  local py_cpuset java_cpuset k6_cpuset
  py_cpuset=$(compose_service_value "python-service" cpuset)
  java_cpuset=$(compose_service_value "transaction-service" cpuset)
  k6_cpuset=$(compose_service_value "k6" cpuset)

  local py_cores java_cores k6_cores total_pinned_cores
  py_cores=$(count_cpuset_cores "${py_cpuset:-}")
  java_cores=$(count_cpuset_cores "${java_cpuset:-}")
  k6_cores=$(count_cpuset_cores "${k6_cpuset:-}")
  total_pinned_cores=$((py_cores + java_cores + k6_cores))

  # Aborts before any container starts if the three cpusets share physical cores with each
  # other, or if any of them owns only part of a physical core on this host.
  verify_smt_isolation "${py_cpuset:-}" "${java_cpuset:-}" "${k6_cpuset:-}"
  verify_service_cpuset "startup" "python-service" "${py_cpuset:-}" "$(compose_service_value "python-service" cpus)"
  verify_service_cpuset "startup" "transaction-service" "${java_cpuset:-}" "$(compose_service_value "transaction-service" cpus)"
  verify_service_cpuset "startup" "k6" "${k6_cpuset:-}" "$(compose_service_value "k6" cpus)"

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "$(json_escape "$timestamp")",
  "host_uname": "$(json_escape "$host_uname")",
  "wsl2_detected": "${IS_WSL2}",
  "docker_version": "$(json_escape "$docker_version")",
  "docker_compose_version": "$(json_escape "$compose_version")",
  "k6_image": "$(json_escape "${k6_image:-unknown}")",
  "k6_image_digest": "$(json_escape "$k6_digest")",
  "git_commit": "$(json_escape "$git_commit")",
  "git_dirty": "$(json_escape "$git_dirty")",
  "cpu_model": "$(json_escape "$cpu_model")",
  "cpu_count": "$(json_escape "$cpu_count")",
  "cpu_governor_at_start": "$(json_escape "$cpu_governor")",
  "cpu_freq_khz_at_start": "$(json_escape "$cpu_freq_khz")",
  "total_mem_kb": "$(json_escape "$total_mem_kb")",
  "host_provenance": $(host_provenance_json),
  "jvm_pinned_options": "$(json_escape "$(jvm_pinned_options)")",
  "cores_used_by_suite": {
    "python_service_cpuset": "$(json_escape "${py_cpuset:-unknown}")",
    "python_service_cores": ${py_cores},
    "transaction_service_cpuset": "$(json_escape "${java_cpuset:-unknown}")",
    "transaction_service_cores": ${java_cores},
    "k6_cpuset": "$(json_escape "${k6_cpuset:-unknown}")",
    "k6_cores": ${k6_cores},
    "total_pinned_cores": ${total_pinned_cores},
    "host_cores_available": "$(json_escape "$cpu_count")",
    "physical_core_isolation": "$(json_escape "$SMT_TOPOLOGY_STATUS")"
  },
  "suite_config": {
    "targets": [$(printf '"%s",' "${TARGETS[@]}" | sed 's/,$//')],
    "concurrency_levels": [$(printf '%s,' "${CONCURRENCY_LEVELS[@]}" | sed 's/,$//')],
    "max_vus": ${MAX_VUS},
    "scan_warmup_includes_max_vus_pass": true,
    "baseline_iterations": ${BASELINE_ITERATIONS},
    "scan_iterations_per_vu": ${SCAN_ITERATIONS_PER_VU},
    "cooldown_s": ${COOLDOWN_S},
    "reps_baseline": ${REPS_BASELINE},
    "reps_scan": ${REPS_SCAN},
    "java_outbound_max_connections": ${PYTHON_SERVICE_MAX_CONNECTIONS},
    "warmup_gate": {
      "chunk_duration_s": ${WARMUP_CHUNK_DURATION_S},
      "max_chunks": ${MAX_WARMUP_CHUNKS},
      "base_window": ${WARMUP_WINDOW},
      "min_window_span_s": ${WARMUP_WINDOW_MIN_S},
      "tail_tolerance_pct": ${WARMUP_TAIL_TOLERANCE_PCT},
      "tail_abs_floor_ms": ${WARMUP_TAIL_ABS_FLOOR_MS}
    },
    "calibration": {
      "reference_vus": ${CALIB_VUS},
      "iterations_per_vu": ${CALIB_ITER_PER_VU},
      "target_duration_s": ${CALIB_TARGET_DURATION_S},
      "affected_levels": [$(tr ' ' ',' <<< "$CALIB_AFFECTED_LEVELS")],
      "scope": "measured once per target in a dedicated pass before the scan reps; every rep runs those counts"
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

  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} (pinned: ${total_pinned_cores}) governor=${cpu_governor} freq_khz=${cpu_freq_khz} git=${git_commit:0:12} wsl2=${IS_WSL2}"
  echo "  [metadata] $(host_provenance_line)"
}

# Counts the logical CPUs in a Docker cpuset string ("3-5", "0,2,4"), so the expected
# JVM processor count tracks the configured cpuset instead of a hard-coded number.
count_cpuset_cores() {
  local cpuset="$1"
  local total=0
  local part lo hi
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

# Expands a cpuset string ("0-2" or "0,2,4") into one logical CPU id per line.
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

# Maps a logical CPU to its physical core via the lowest-numbered SMT sibling.
core_key_of_cpu() {
  local siblings="/sys/devices/system/cpu/cpu${1}/topology/thread_siblings_list"
  [ -r "$siblings" ] || return 0
  sed 's/[,-].*//' "$siblings" | tr -d ' \n'
}

# Comma-joined, deduplicated physical-core keys backing a cpuset.
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

# Aborts if cpuset assignments share physical cores via SMT siblings.
# Prevents hyperthread contention from inflating measured inference latency.
verify_smt_isolation() {
  local py_cpuset="$1" java_cpuset="$2" k6_cpuset="$3"

  if [ ! -r /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]; then
    echo "  [smt] WARNING: SMT topology is not exposed on this host (common under WSL2)."
    echo "  [smt] Physical-core disjointness is UNVERIFIED for this run; recorded in run_metadata.json."
    echo "smt_check status=unverifiable reason=topology_not_exposed" >> "$CPU_PIN_LOG"
    SMT_TOPOLOGY_STATUS="unverifiable (thread_siblings_list not exposed)"
    return 0
  fi

  local py_keys java_keys k6_keys
  py_keys=$(core_keys_of_cpuset "$py_cpuset")
  java_keys=$(core_keys_of_cpuset "$java_cpuset")
  k6_keys=$(core_keys_of_cpuset "$k6_cpuset")

  local py_unres java_unres k6_unres
  py_unres=$(unresolved_cpus_in_cpuset "$py_cpuset")
  java_unres=$(unresolved_cpus_in_cpuset "$java_cpuset")
  k6_unres=$(unresolved_cpus_in_cpuset "$k6_cpuset")
  if [ "$py_unres" -gt 0 ] || [ "$java_unres" -gt 0 ] || [ "$k6_unres" -gt 0 ]; then
    abort_suite "[smt]" "could not resolve a physical core for every pinned CPU" \
      "(unresolved: python=${py_unres} java=${java_unres} k6=${k6_unres}). Those CPUs would be" \
      "dropped from the overlap comparison, which could report isolation that does not hold." \
      "Check that every CPU in the cpusets exists and is online on this host."
  fi
  if [ -z "$py_keys" ] || [ -z "$java_keys" ] || [ -z "$k6_keys" ]; then
    abort_suite "[smt]" "at least one cpuset resolved to no physical cores at all" \
      "(python=${py_keys:-EMPTY} java=${java_keys:-EMPTY} k6=${k6_keys:-EMPTY})." \
      "An empty cpuset means the compose configuration was never read, not that the services" \
      "are disjoint -- refusing to report physical-core isolation as verified."
  fi

  echo "  [smt] physical cores -- python(${py_keys:-EMPTY}) java(${java_keys:-EMPTY}) k6(${k6_keys:-EMPTY})"
  echo "smt_check python_cores=${py_keys:-EMPTY} java_cores=${java_keys:-EMPTY} k6_cores=${k6_keys:-EMPTY}" >> "$CPU_PIN_LOG"
  SMT_TOPOLOGY_STATUS="python=${py_keys:-EMPTY} java=${java_keys:-EMPTY} k6=${k6_keys:-EMPTY}"

  local pair_a pair_b shared
  for pair in "python:${py_keys}:java:${java_keys}" \
              "python:${py_keys}:k6:${k6_keys}" \
              "java:${java_keys}:k6:${k6_keys}"; do
    IFS=':' read -r name_a pair_a name_b pair_b <<< "$pair"
    shared=$(comm -12 \
      <(tr ',' '\n' <<< "$pair_a" | sort -u) \
      <(tr ',' '\n' <<< "$pair_b" | sort -u) | paste -sd, -)
    if [ -n "$shared" ]; then
      abort_suite "[smt]" "${name_a} and ${name_b} are pinned to SMT siblings of the same physical" \
        "core(s) (${shared}). Their cpusets are disjoint but the hardware is not, so neither" \
        "service is actually isolated. Re-pick cpusets in docker-compose.yml using one logical" \
        "CPU per physical core (see thread_siblings_list)."
    fi
  done

  echo "  [smt] OK -- python, java and k6 occupy disjoint physical cores."
}

# Reads the cpuset a container was actually assigned by the kernel, not what
# it was configured with. Tries cgroup v2 first, falls back to v1.
read_live_cpuset() {
  local container="$1"
  docker exec "$container" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}


# Any invalidating condition -- pinning, tier loading, thermal, or a cell
# failure -- tears the stack down and exits rather than continuing to produce
# output that analysis would reject wholesale anyway.
abort_suite() {
  local label="$1"; shift
  local reason="$*"  # join remaining args -- callers pass the message across multiple lines
  # >&2 on every line: some callers (e.g. jvm_container()) run inside a caller's
  # $( ), which would otherwise capture tee's stdout copy into that caller's
  # variable instead of letting it reach the console.
  echo "" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] ${label}: ${reason}" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] Aborting suite. No results were written for this rep. Prior reps" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] already on disk in ${RESULTS_DIR} are unaffected and can be kept," | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] but this suite invocation is incomplete -- fix the cause and" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] re-run run-suite.sh from the beginning." | tee -a "$FAILURES_LOG" >&2
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

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

  # Reads "Effective CPU Count" from `-XshowSettings:system` (JDK 10+), the value
  # backing Runtime.availableProcessors() and so the Netty event-loop sizing.
  # The probe JVM inherits JAVA_TOOL_OPTIONS, so it reopens -- and truncates --
  # /gc-logs/gc.log, as do verify_jvm_flag_pins()'s probes after it. The last probe,
  # between readiness and warm-up, is where each rep's archived GC log starts;
  # table_gc_overhead spans it by the records' wall-clock timestamps.
  local java_cpus expected_java_cpus
  java_cpus=$(docker exec "$java_container" sh -c \
    'java -XshowSettings:system -version 2>&1 | grep -i "Effective CPU Count" | grep -o "[0-9]*"' \
    2>/dev/null || echo "")
  expected_java_cpus=$(count_cpuset_cores "$java_requested")
  echo "  [cpu-pin] ${label}: JVM-reported effective CPU count(${java_cpus:-EMPTY}), expected(${expected_java_cpus:-EMPTY} from requested cpuset ${java_requested:-EMPTY})"
  echo "cpu_pin_check label=${label} jvm_effective_cpu_count=${java_cpus:-EMPTY} expected_from_cpuset=${expected_java_cpus:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ -z "$java_cpus" ]; then
    abort_suite "[cpu-pin] ${label}" "could not read the JVM-reported Effective CPU Count -- Netty event-loop" \
      "sizing is unverifiable for this rep."
  elif [ -z "$expected_java_cpus" ] || [ "$expected_java_cpus" = "0" ]; then
    abort_suite "[cpu-pin] ${label}" "could not derive an expected core count from the requested cpuset" \
      "(${java_requested:-EMPTY}) -- cannot verify JVM core detection for this rep."
  elif [ "$java_cpus" != "$expected_java_cpus" ]; then
    abort_suite "[cpu-pin] ${label}" "JVM reports ${java_cpus} effective CPUs, expected ${expected_java_cpus}" \
      "(derived from requested cpuset ${java_requested}). availableProcessors() sizes Reactor Netty's" \
      "event-loop pool (max(availableProcessors(), 4)), ForkJoinPool.commonPool, the G1 worker threads" \
      "and the JIT compiler threads -- all of them would be sized off the wrong core count for this rep."
  fi

  # Verifies the k6 container's own cpuset against the compose file, which is also what
  # verify_smt_isolation() compared, so the two can never disagree about what was asked for.
  # `docker compose run --rm` can hang on cleanup of the ephemeral container; timeout
  # bounds it, and -k 10 sends SIGKILL if SIGTERM doesn't land.
  local k6_expected
  k6_expected=$(compose_service_value "k6" cpuset)
  local k6_live k6_rc
  set +e
  k6_live=$(timeout -k 10 30 docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T --entrypoint sh k6 \
    -c 'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null)
  k6_rc=$?
  set -e
  echo "  [cpu-pin] ${label}: k6 live(${k6_live:-EMPTY}) expected(${k6_expected})"
  echo "cpu_pin_check label=${label} k6_live=${k6_live:-EMPTY} k6_expected=${k6_expected}" >> "$CPU_PIN_LOG"
  if [ "$k6_rc" -eq 124 ]; then
    echo "  [cpu-pin] ${label}: WARN -- k6 cpuset read timed out after 30s and was killed;" \
      "skipping k6 pin check for this rep. Not an environment limitation -- check" \
      "'docker compose version' if this recurs."
    echo "cpu_pin_check label=${label} k6_live=TIMEOUT k6_expected=${k6_expected} result=WARN_SKIPPED_TIMEOUT" >> "$CPU_PIN_LOG"
  elif [ -z "$k6_live" ]; then
    echo "  [cpu-pin] ${label}: WARN -- could not read k6 cgroup cpuset (WSL2/cgroup-v2 limitation); skipping k6 pin check."
    echo "cpu_pin_check label=${label} k6_live=UNREADABLE k6_expected=${k6_expected} result=WARN_SKIPPED" >> "$CPU_PIN_LOG"
  elif [ "$k6_live" != "$k6_expected" ]; then
    abort_suite "[cpu-pin] ${label}" "k6's live cgroup cpuset (${k6_live}) does not match the requested" \
      "cpuset (${k6_expected}) -- k6 core isolation was not honored on this Docker/cgroup driver version."
  fi

  echo "  [cpu-pin] ${label}: OK -- pinning verified, proceeding."
}

# Confirms python-service's /health reports the expected loaded tiers and
# n_jobs=1 verification -- a silent tier-load failure wouldn't otherwise
# show up as a request-level error.
verify_tiers() {
  local label="$1"
  local health_json
  health_json=$(curl -s http://localhost:8000/health 2>/dev/null || echo "")
  if [ -z "$health_json" ]; then
    abort_suite "[tier-check] ${label}" "could not reach python-service's /health -- tier loading is unverifiable."
  fi

  local loaded_tiers all_verified
  loaded_tiers=$(echo "$health_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(",".join(sorted((str(t) for t in data.get("loadedTiers", [])), key=int)))
except Exception:
    print("")
')
  all_verified=$(echo "$health_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    v = data.get("nJobsVerified", {})
    # Requires real booleans: all({}.values()) is True for an empty mapping, and a
    # truthy non-bool (e.g. "false") would pass too.
    print("true" if isinstance(v, dict) and v and all(x is True for x in v.values()) else "false")
except Exception:
    print("false")
')

  echo "  [tier-check] ${label}: loaded(${loaded_tiers:-EMPTY}) expected(${EXPECTED_TIERS}) n_jobs_verified(${all_verified})"
  echo "cpu_pin_check label=${label} tiers_loaded=${loaded_tiers:-EMPTY} tiers_expected=${EXPECTED_TIERS} n_jobs_verified=${all_verified}" >> "$CPU_PIN_LOG"

  local thread_env
  thread_env=$(echo "$health_json" | python3 -c '
import json, sys
try:
    env = json.load(sys.stdin).get("numericThreadEnv", {})
    print(",".join(f"{k}={v}" for k, v in sorted(env.items())))
except Exception:
    print("")
')
  echo "  [tier-check] ${label}: numeric_thread_env(${thread_env:-EMPTY})"
  echo "cpu_pin_check label=${label} numeric_thread_env=${thread_env:-EMPTY}" >> "$CPU_PIN_LOG"

  local live_tokens
  live_tokens=$(echo "$health_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("threadLimiterTokens", ""))
except Exception:
    print("")
')
  echo "  [tier-check] ${label}: thread_limiter_tokens(${live_tokens:-EMPTY} expected ${EXPECTED_THREAD_LIMITER_TOKENS})"
  echo "cpu_pin_check label=${label} thread_limiter_tokens=${live_tokens:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ "$loaded_tiers" != "$EXPECTED_TIERS" ]; then
    abort_suite "[tier-check] ${label}" "python-service's /health loadedTiers (${loaded_tiers:-EMPTY})" \
      "does not match expected (${EXPECTED_TIERS})."
  elif [ "$all_verified" != "true" ]; then
    abort_suite "[tier-check] ${label}" "python-service's /health nJobsVerified reports at least one" \
      "tier without n_jobs pinned to 1 -- single-threaded inference guarantee not met."
  elif [ "$live_tokens" != "$EXPECTED_THREAD_LIMITER_TOKENS" ]; then
    abort_suite "[tier-check] ${label}" "python-service's /health threadLimiterTokens (${live_tokens:-EMPTY})" \
      "!= expected (${EXPECTED_THREAD_LIMITER_TOKENS}) -- the pinned baseline did not take effect."
  fi

  # Asserts every BLAS/OpenMP layer is pinned to one thread alongside n_jobs=1.
  # The match is comma-delimited because a bare *OMP_NUM_THREADS=1* substring would
  # also accept 10, 16, 100 or 1024.
  local tvar
  for tvar in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS NUMEXPR_NUM_THREADS; do
    case ",${thread_env}," in
      *",${tvar}=1,"*) ;;
      *) abort_suite "[tier-check] ${label}" "python-service reports ${tvar} not pinned to exactly 1" \
           "(${thread_env:-EMPTY}) -- numeric libraries may spawn threads outside the measured cpuset." ;;
    esac
  done
}

# Re-checks n_jobs after warm-up, when every tier in this run has served inference.
# /health is answered by one uvicorn worker, so this polls until it has seen the
# configured worker count or exhausts its attempts, and reports how many it covered.
verify_tiers_runtime() {
  local label="$1"
  local expected_workers target has_inference=""
  for target in "${TARGETS[@]}"; do
    case ",${EXPECTED_TIERS}," in *",${target},"*) has_inference=1 ;; esac
  done
  if [ -z "$has_inference" ]; then
    echo "  [tier-runtime] ${label}: no inference target in this run, so no tier has served inference to verify."
    return 0
  fi
  # Reads the resolved compose config rather than this shell's own UVICORN_WORKERS:
  # a value set via .env (which compose reads directly) would never reach this
  # process's environment, leaving the poll count silently wrong for whatever the
  # container actually started with.
  expected_workers=$(compose_service_value "python-service" UVICORN_WORKERS)
  if [ -z "$expected_workers" ]; then
    abort_suite "[tier-runtime] ${label}" "could not resolve UVICORN_WORKERS from the resolved compose" \
      "config for python-service -- the worker count to poll for is unknown rather than assumed."
  fi
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
      abort_suite "[tier-runtime] ${label}" "could not read nJobsRuntimeVerified from python-service's /health."
    elif [ "$runtime_state" = "unexercised" ]; then
      continue
    elif [ "$runtime_state" != "ok" ]; then
      abort_suite "[tier-runtime] ${label}" "tier(s) reported n_jobs != 1 after serving inference" \
        "(${runtime_state}) on worker ${pid:-unknown} -- the single-threaded guarantee held at load" \
        "time but not at run time."
    fi

    case " ${seen_pids} " in
      *" ${pid} "*) ;;
      *) seen_pids="${seen_pids}${pid} " ;;
    esac
    [ "$(echo "$seen_pids" | wc -w)" -ge "$expected_workers" ] && break
  done

  local n_seen
  n_seen=$(echo "$seen_pids" | wc -w)
  echo "  [tier-runtime] ${label}: ok on ${n_seen}/${expected_workers} worker(s) (pids: ${seen_pids% })"
  echo "cpu_pin_check label=${label} n_jobs_runtime=ok workers_checked=${n_seen} workers_expected=${expected_workers}" \
    >> "$CPU_PIN_LOG"

  if [ "$n_seen" -lt "$expected_workers" ]; then
    echo "  [tier-runtime] ${label}: WARN -- only ${n_seen} of ${expected_workers} workers reported a tier" \
         "verified after serving inference across ${attempts} polls; the others are unverified for this rep." >&2
  fi
}

restart_stack() {
  echo "  [restart] tearing down stack for a clean slate..."
  docker compose -f "$COMPOSE_FILE" down
  echo "  [restart] bringing stack back up..."
  docker compose -f "$COMPOSE_FILE" up -d --wait
}
# Poll API endpoint until Spring app accepts traffic.
# Note: `docker compose --wait` only checks containers with healthchecks (python-service).
wait_for_ready() {
  local url="http://localhost:8080/api/v1/transactions"
  local max_attempts=60
  local status
  for i in $(seq 1 "$max_attempts"); do
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" \
      -d '{"transactionId":"00000000-0000-0000-0000-000000000000","accountId":"ACC-0000","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}'   \
      2>/dev/null) || status="000"
    if [ "$status" = "200" ]; then
      echo "  [ready] transaction-service responded 200 after ${i} attempt(s)."
      return 0
    fi
    sleep 2
  done
  # Routed through abort_suite so a readiness timeout lands in the failures log like
  # any other invalidating condition; a bare non-zero exit would leave that log clean
  # and let analyze-results.py accept the partial dataset.
  abort_suite "[ready]" "transaction-service did not respond 200 within ${max_attempts} attempts" \
    "(last status ${status:-none}) -- the stack never became ready for this rep."
}

shuffled() {
  printf '%s\n' "$@" | shuf | tr '\n' ' '
}

# Runs a k6 script in its own container, pinned to the cpuset in docker-compose.yml.
# Usage: k6_run <script.js> [KEY=VALUE ...] -- <k6-args...>
# KEY=VALUE pairs before `--` are passed as `-e KEY=VALUE` to the container.
k6_run() {
  local script="$1"; shift
  local env_flags=()
  while [ "$1" != "--" ]; do
    env_flags+=("-e" "$1")
    shift
  done
  shift # drop the --
  docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T \
    "${env_flags[@]}" k6 run "/scripts/${script}" "$@"
}

# Filters a raw k6 JSON trail down to KEEP_METRICS and gzips it into
# RESULTS_DIR, then deletes the raw copy. Runs on the host, after the
# container that wrote the raw file has already exited.
# Usage: finalize_result <name.json>  -- name matches what --out json=
# pointed at under /results/raw/ (container path) / RAW_RESULTS_DIR (host path).
finalize_result() {
  local name="$1"
  python3 "${LIB_DIR}/k6_filter.py" finalize "${RAW_RESULTS_DIR}/${name}" "${RESULTS_DIR}/${name}.gz" "$KEEP_METRICS"
  rm -f "${RAW_RESULTS_DIR}/${name}"
}

# Filters a raw k6 JSON chunk down to KEEP_METRICS and appends it to a plain
# (uncompressed) file, so converge_warmup never accumulates raw chunks.
filter_chunk() {
  python3 "${LIB_DIR}/k6_filter.py" append "$1" "$2" "$KEEP_METRICS"
}

# Gzips an already-filtered file and deletes the plain copy.
gzip_only() {
  python3 "${LIB_DIR}/k6_filter.py" gzip "$1" "$2"
  rm -f "$1"
}

# Warm-up runs in WARMUP_CHUNK_DURATION_S chunks until every target has converged or
# MAX_WARMUP_CHUNKS have run: targets settle at different rates, and a fixed budget
# either wastes time on the fast ones or short-changes the slow ones. The criterion is
# lib/warmup_gate.py, which table0 also reads, so the table reports the verdict this
# gate acted on. Per target, the median of the last window is compared with the window
# before it and passes within WARMUP_TAIL_TOLERANCE_PCT or WARMUP_TAIL_ABS_FLOOR_MS (a
# percentage alone is unreachably tight for sub-millisecond round trips). A window is at
# least WARMUP_WINDOW requests spanning at least WARMUP_WINDOW_MIN_S seconds: that covers
# several GC and scheduler cycles at every target's throughput, and three windows still
# fit in one chunk, so the first chunk can pass. A target with no HTTP 200 response never
# converges. An explicit WARMUP_ITERATIONS_PER_TARGET skips the gate for a single
# fixed-iteration pass.
WARMUP_CHUNK_DURATION_S=15
MAX_WARMUP_CHUNKS=4
WARMUP_WINDOW=500
WARMUP_WINDOW_MIN_S=3
WARMUP_TAIL_TOLERANCE_PCT=5.0
WARMUP_TAIL_ABS_FLOOR_MS=0.25
WARMUP_TABLE="table0_warmup_convergence_check"

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

# Measures this target's throughput at CALIB_VUS, then derives the
# ITERATIONS_PER_VU each of CALIB_AFFECTED_LEVELS needs to hit
# CALIB_TARGET_DURATION_S, into CALIB_ITERATIONS_PER_VU. Throughput is roughly
# flat across VUS within a target but differs by a large factor between targets,
# so no single iteration count reaches the same wall-clock duration for all of them.
calibrate_target() {
  local target="$1"
  local raw_name="calib_${target}_vus${CALIB_VUS}.json"
  echo "  [calibrate] target=${target}: measuring throughput at VUS=${CALIB_VUS}..."
  k6_run run-target.js \
    TARGET="$target" VUS="$CALIB_VUS" ITERATIONS_PER_VU="$CALIB_ITER_PER_VU" PHASE=scan REP=calib -- \
    --out "json=/results/raw/${raw_name}"
  finalize_result "$raw_name"

  local host_path="${RESULTS_DIR}/${raw_name}.gz"
  local vus iters
  # Cleared before each target: the derivation runs in a process substitution whose
  # exit status is unreachable, so a calibration that yields no rows would otherwise
  # leave the previous target's counts in place and silently calibrate this target
  # against another target's throughput.
  CALIB_ITERATIONS_PER_VU=()
  while read -r vus iters; do
    CALIB_ITERATIONS_PER_VU[$vus]="$iters"
  done < <(python3 - "$host_path" "$CALIB_TARGET_DURATION_S" $CALIB_AFFECTED_LEVELS <<'PYEOF'
import gzip, json, re, sys
from datetime import datetime

def parse_iso(ts):
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts)
    return datetime.fromisoformat(ts)

fp, target_s = sys.argv[1], float(sys.argv[2])
levels = [int(v) for v in sys.argv[3:]]
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
        if tags.get("phase") != "scan":
            continue
        # A failed request (connection error, timeout, DNS failure) still emits a
        # phase=scan point; counting it in would derive throughput -- and therefore
        # every level's iteration count -- from traffic that never reached the
        # service. Same filter analyze-results.py applies before its own throughput
        # calcs (e.g. table2's scan-phase e2e figures).
        if tags.get("status") != "200":
            continue
        times.append(parse_iso(obj["data"]["time"]))
times.sort()
if len(times) < 2:
    sys.exit(f"calibration produced {len(times)} usable scan point(s); need at least 2")
duration = (times[-1] - times[0]).total_seconds()
if duration <= 0:
    sys.exit("calibration points all share one timestamp; cannot derive throughput")
# N completion timestamps bound N-1 inter-completion intervals, so the rate over that
# span is (N-1)/span -- same convention as analyze-results.py's _throughput_reqs_per_s.
# N/span overestimates by a factor of N/(N-1), negligible at real cell sizes but not
# the same quantity.
throughput = (len(times) - 1) / duration
target_total_requests = throughput * target_s
for vus in levels:
    print(vus, max(1, round(target_total_requests / vus)))
PYEOF
  )
  local summary=""
  for vus in $CALIB_AFFECTED_LEVELS; do
    if [ -z "${CALIB_ITERATIONS_PER_VU[$vus]:-}" ]; then
      abort_suite "[calibrate] target=${target}: no iteration count derived for VUS=${vus}." \
                  "The calibration cell produced no usable scan points (see ${raw_name}.gz)."
    fi
    summary="${summary}VUS${vus}=${CALIB_ITERATIONS_PER_VU[$vus]} "
  done
  echo "  [calibrate] target=${target}: ${summary% }"
}

# Calibrates every target once, on a stack prepared exactly like a scan rep (restart,
# pin checks, both gated warm-up passes) that then runs no measured cell. Calibrating
# inside a rep would give that rep's cells a load history the other reps lack, and
# calibrating in every rep would let each rep of a cell run a different workload.
# Skipped when no scan level is calibrated.
calibrate_scan_targets() {
  local vus target needed="false"
  for vus in "${CONCURRENCY_LEVELS[@]}"; do
    case " ${CALIB_AFFECTED_LEVELS} " in *" ${vus} "*) needed="true" ;; esac
  done
  if [ "$needed" != "true" ] || [ "$REPS_SCAN" -lt 1 ]; then
    return 0
  fi

  echo "[*] E2 calibration: each target's throughput at VUS=${CALIB_VUS}, measured once for every scan rep"
  record_env_sample "scan_calibration_start"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "scan calibration"
  verify_jvm_flag_pins "scan calibration"
  verify_tiers "scan calibration"
  converge_warmup "calib_warmup_scan" "${WARMUP_ENV_ARGS[@]}" "REP=calib"
  verify_tiers_runtime "scan calibration"
  verify_jvm_thread_pins "scan calibration"
  sleep "$COOLDOWN_S"
  converge_warmup "calib_warmup_scan_maxvus" "${WARMUP_MAXVUS_ENV_ARGS[@]}" WARMUP_VUS="$MAX_VUS" "REP=calib"
  sleep "$COOLDOWN_S"

  local -a targets_order
  read -ra targets_order <<< "$(shuffled "${TARGETS[@]}")"
  for target in "${targets_order[@]}"; do
    calibrate_target "$target"
    local summary=""
    for vus in $CALIB_AFFECTED_LEVELS; do
      CALIB_CACHE[${target}:${vus}]="${CALIB_ITERATIONS_PER_VU[$vus]}"
      summary="${summary}VUS${vus}=${CALIB_ITERATIONS_PER_VU[$vus]} "
    done
    echo "calibration target=${target} ${summary% }" >> "$CALIB_LOG"
    check_thermal_safety "scan calibration target=${target}"
    sleep "$COOLDOWN_S"
  done
  record_env_sample "scan_calibration_end"
}

# Loads a target's calibrated counts into CALIB_ITERATIONS_PER_VU before its VUS loop.
use_calibration() {
  local target="$1" vus
  CALIB_ITERATIONS_PER_VU=()
  for vus in $CALIB_AFFECTED_LEVELS; do
    if [ -n "${CALIB_CACHE[${target}:${vus}]:-}" ]; then
      CALIB_ITERATIONS_PER_VU[$vus]="${CALIB_CACHE[${target}:${vus}]}"
    fi
  done
}

# Aborts the suite if either container was OOM-killed during the cell.
check_oom_killed() {
  local label="$1"
  local py_container java_container py_oom java_oom
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

# Moves the JVM's GC log to a rep-labeled file before the next restart_stack
# starts a fresh JVM over it. Call once per rep, after that rep's cells, so the
# archived window is the one the probe JVM opened at rep start.
archive_gc_log() {
  local label="$1"
  local src="$RESULTS_DIR/gc-logs/gc.log"
  local dest="$RESULTS_DIR/gc-logs/gc_${label}.log"
  if [ -f "$src" ]; then
    mv "$src" "$dest"
  else
    # Not written to FAILURES_LOG: a missing GC log leaves that rep out of the GC
    # table but does not invalidate its latency data, and any entry in that log
    # makes analyze-results.py refuse the whole dataset.
    echo "  [!] No GC log found at ${src} for ${label}; GC overhead is unreported for this rep." >&2
  fi
}

# Runs one measured cell, named by its result file's stem, between two thermal
# samples. Aborts the suite on a k6 failure -- no benefit to continuing once
# analyze-results.py will reject the whole run anyway.
run_cell() {
  local label="$1" cell="$2"
  shift 2
  record_cell_thermal start "$cell"
  if ! "$@"; then
    abort_suite "[cell] ${label}" "k6 exited non-zero."
  fi
  record_cell_thermal end "$cell"
  check_oom_killed "$label"
  check_thermal_safety "$label"
}

capture_run_metadata

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  record_env_sample "baseline_rep${rep}_start"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "baseline rep=${rep}"
  verify_jvm_flag_pins "baseline rep=${rep}"
  verify_tiers "baseline rep=${rep}"
  echo "[*] Warming up JIT / connection pools..."
  converge_warmup "warmup_baseline_rep${rep}" "${WARMUP_ENV_ARGS[@]}" "REP=${rep}"
  verify_tiers_runtime "baseline rep=${rep}"
  verify_jvm_thread_pins "baseline rep=${rep}"
  sleep "$COOLDOWN_S"

  # Independent per-rep shuffle of target order.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  echo "baseline rep=${rep} target_order=${TARGETS_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    echo "  -> target=${target} rep=${rep}"
    run_cell "baseline target=${target} rep=${rep}" "baseline_${target}_rep${rep}" \
      k6_run run-target.js \
      TARGET="$target" VUS=1 ITERATIONS="$BASELINE_ITERATIONS" PHASE=baseline REP="$rep" -- \
      --out "json=/results/raw/baseline_${target}_rep${rep}.json"
    finalize_result "baseline_${target}_rep${rep}.json"
    sleep "$COOLDOWN_S"
  done
  record_env_sample "baseline_rep${rep}_end"
  archive_gc_log "baseline_rep${rep}"
done

calibrate_scan_targets

echo "[*] E2: concurrency scan x ${REPS_SCAN} independent repetitions"
for rep in $(seq 1 "$REPS_SCAN"); do
  echo "[*] --- Scan repetition ${rep}/${REPS_SCAN} ---"
  record_env_sample "scan_rep${rep}_start"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "scan rep=${rep}"
  verify_jvm_flag_pins "scan rep=${rep}"
  verify_tiers "scan rep=${rep}"
  echo "[*] Warming up JIT / connection pools (default VUS)..."
  converge_warmup "warmup_scan_rep${rep}" "${WARMUP_ENV_ARGS[@]}" "REP=${rep}"
  verify_tiers_runtime "scan rep=${rep}"
  verify_jvm_thread_pins "scan rep=${rep}"
  sleep "$COOLDOWN_S"

  # Matches warm-up concurrency to the scan's peak VUS; separate output
  # file so table0's convergence check can report on it distinctly.
  echo "[*] Warming up JIT / connection pools (MAX_VUS=${MAX_VUS})..."
  converge_warmup "warmup_scan_maxvus_rep${rep}" "${WARMUP_MAXVUS_ENV_ARGS[@]}" WARMUP_VUS="$MAX_VUS" "REP=${rep}"
  sleep "$COOLDOWN_S"

  # Randomizes target and concurrency order per rep (shuffled independently)
  # to decorrelate within-rep drift from individual test factors.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  read -ra CONCURRENCY_THIS_REP <<< "$(shuffled "${CONCURRENCY_LEVELS[@]}")"
  echo "scan rep=${rep} target_order=${TARGETS_THIS_REP[*]} concurrency_order=${CONCURRENCY_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"
  echo "  [order] concurrency levels this rep: ${CONCURRENCY_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    use_calibration "$target"
    for vus in "${CONCURRENCY_THIS_REP[@]}"; do
      iter_per_vu="$SCAN_ITERATIONS_PER_VU"
      if [ -n "${CALIB_ITERATIONS_PER_VU[$vus]:-}" ]; then
        iter_per_vu="${CALIB_ITERATIONS_PER_VU[$vus]}"
      fi
      echo "  -> target=${target} vus=${vus} rep=${rep} iterations_per_vu=${iter_per_vu}"
      run_cell "scan target=${target} vus=${vus} rep=${rep}" "scan_${target}_vus${vus}_rep${rep}" \
        k6_run run-target.js \
        TARGET="$target" VUS="$vus" ITERATIONS_PER_VU="$iter_per_vu" PHASE=scan REP="$rep" -- \
        --out "json=/results/raw/scan_${target}_vus${vus}_rep${rep}.json"
      finalize_result "scan_${target}_vus${vus}_rep${rep}.json"
      sleep "$COOLDOWN_S"
    done
  done
  record_env_sample "scan_rep${rep}_end"
  archive_gc_log "scan_rep${rep}"
done

echo "[+] Suite complete. Raw results in ${RESULTS_DIR}/"
echo "    Per-rep cell order logged to ${ORDER_LOG}"
echo "    Host/toolchain fingerprint (incl. physical-core isolation) logged to ${METADATA_FILE}"
echo "    CPU pinning, SMT topology and thread-env checks logged to ${CPU_PIN_LOG}"
echo "    Per-rep governor/frequency/temperature and per-cell thermal samples logged to ${ENV_TRACE_LOG}"
echo "    Warm-up JSON output (for post-hoc convergence check) saved as warmup_baseline_rep*.json.gz,"
echo "    warmup_scan_rep*.json.gz (default VUS), and warmup_scan_maxvus_rep*.json.gz (VUS=${MAX_VUS})"
echo "    'calibration' target included alongside mock/5/10/20/28 -- isolates instrumentation overhead"
echo "    Calibration pass (calib_*.json.gz, not read by analyze-results.py): the iteration counts"
echo "    every scan rep ran with are logged to ${CALIB_LOG}"
# Guards against an empty run: "every rep passed" below is vacuously true if no cell ran.
_n_cells=$(find "$RESULTS_DIR" -maxdepth 1 \( -name 'baseline_*.json.gz' -o -name 'scan_*.json.gz' \) 2>/dev/null | wc -l)
if [ "$_n_cells" -eq 0 ]; then
  abort_suite "[suite]" "no measurement cells were executed -- check TARGETS_OVERRIDE," \
    "CONCURRENCY_OVERRIDE and REPS_*_OVERRIDE. Not reporting this run as successful."
fi
echo "    No cell failures -- every rep passed cpu-pin and tier verification."
echo "    Run: ../analysis/venv/bin/python3 ../analysis/analyze-results.py"