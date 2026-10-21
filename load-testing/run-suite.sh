#!/usr/bin/env bash
set -euo pipefail

# Detaches stdin: a backgrounded docker compose invocation that inherits the
# terminal's stdin gets stopped by SIGTTIN the moment it tries to read it.
exec < /dev/null

# Runs E1 (baseline, VUs=1) and E2 (concurrency scan): a stack restart per rep, shuffled cell
# order, guards on CPU pinning, JVM pins, thread caps (n_jobs, BLAS/OpenMP) and the CPU power
# state, and host provenance in run_metadata.json.

# Relative paths below resolve from the script's directory.
cd "$(dirname "${BASH_SOURCE[0]}")"
LIB_DIR="${PWD}/lib"

# Preflight: fail before any container is touched. k6 itself runs in its own pinned
# container (the `k6` service in docker-compose.yml), so it is not a host requirement.
for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

for _req_lib in lib/host-provenance.sh lib/power-state.sh lib/jvm-pins.sh lib/topology.sh lib/thermal.sh \
  lib/run-layout.sh lib/suite-stack.sh lib/warmup_gate.py lib/k6_filter.py lib/placement.py lib/cpufreq_sampler.py; do
  if [ ! -r "$_req_lib" ]; then
    echo "[!] Required helper not found: ${_req_lib}. Aborting before touching any containers." >&2
    exit 1
  fi
done

# Host-state provenance for run_metadata.json, the CPU power state every cell is checked
# against, the JVM collector/thread-pool guards, the topology checks that decide whether
# this host's cpusets mean what they say, the thermal guard and telemetry, the per-run
# results directory, and the restarts, per-rep guards, warm-up gate and cell wrapper.
. lib/host-provenance.sh
. lib/power-state.sh
. lib/jvm-pins.sh
. lib/topology.sh
. lib/thermal.sh
. lib/run-layout.sh
. lib/suite-stack.sh

# The sysfs roots are test hooks; a real run must read the live host's /sys.
for _sysfs_var in TOPO_SYSFS_ROOT THERMAL_SYSFS_ROOT POWER_SYSFS_ROOT; do
  if [ "${!_sysfs_var:-/sys}" != "/sys" ]; then
    echo "[!] ${_sysfs_var} is set to '${!_sysfs_var}'. The suite reads the live host only;" >&2
    echo "    unset it before running." >&2
    exit 1
  fi
done

# Turbo is a fixed run parameter: with it on, a laptop's clock follows its temperature
# history, so a cell's speed would depend on the cells before it. Checked before the run
# directory is created, so a refused start leaves results/ untouched.
REQUIRED_TURBO="${REQUIRED_TURBO_OVERRIDE:-off}"
case "$REQUIRED_TURBO" in
  on|off) ;;
  *) echo "[!] REQUIRED_TURBO_OVERRIDE must be on or off, got '${REQUIRED_TURBO}'." >&2; exit 1 ;;
esac
require_prepared_host "$REQUIRED_TURBO"

# On WSL2 the cgroup cpuset checks pass but Hyper-V can move virtual CPUs across physical
# cores unobserved, so pinning is unconfirmed. Recorded in run_metadata.json, not fatal.
IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- physical-core pinning is not guaranteed even when" >&2
  echo "    verify_cpu_pinning() reports OK (see README Threats to validity)." >&2
  echo "    Recorded in run_metadata.json for this run." >&2
fi

# Set by verify_smt_isolation() during metadata capture; recorded in run_metadata.json.
SMT_TOPOLOGY_STATUS="not checked"

# COMPOSE_FILE_OVERRIDE and RESULTS_DIR_OVERRIDE (prepare_run_dir) let the fault-injection
# suite run against a patched configuration without writing into a real dataset.
COMPOSE_FILE="${COMPOSE_FILE_OVERRIDE:-../docker-compose.yml}"
prepare_run_dir ../results suite
# k6's unfiltered output (/results/raw in the container). finalize_result() filters and
# gzips each file into RESULTS_DIR and deletes the raw copy, so this is empty between cells.
RAW_RESULTS_DIR="${RESULTS_DIR}/raw"
rm -rf "$RAW_RESULTS_DIR"
mkdir -p "$RESULTS_DIR/gc-logs" "$RAW_RESULTS_DIR"
# docker-compose.yml mounts this directory at /results for k6 and its gc-logs/ at /gc-logs
# for the JVM.
RUN_RESULTS_DIR=$(cd "$RESULTS_DIR" && pwd)
export RUN_RESULTS_DIR
echo "[*] Run directory: ${RUN_RESULTS_DIR}"

ORDER_LOG="${RESULTS_DIR}/run_order_log.txt"
: > "$ORDER_LOG"   # truncate/create fresh each suite run
METADATA_FILE="${RESULTS_DIR}/run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/run_failures_log.txt"
# Both analysis scripts refuse a run whose failures log is non-empty, so every abort must
# write to it. This catch-all writes only when nothing more specific already did.
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
# temperature and throttle counters at both edges of every measured cell, each cell's
# service-core clock (lib/cpufreq_sampler.py), and every thermal check with the time it
# paused for (see lib/thermal.sh).
ENV_TRACE_LOG="${RESULTS_DIR}/env_trace_log.txt"
: > "$ENV_TRACE_LOG"   # truncate/create fresh each suite run
# The duration-targeted iteration counts every scan rep runs each target with.
CALIB_LOG="${RESULTS_DIR}/calibration_log.txt"
: > "$CALIB_LOG"
# Which python-service worker holds each inbound connection during every measured cell
# (lib/placement.py).
PLACEMENT_LOG="${RESULTS_DIR}/connection_placement_log.txt"
: > "$PLACEMENT_LOG"

TARGETS=(${TARGETS_OVERRIDE:-mock calibration 5 10 20 28})
CONCURRENCY_LEVELS=(${CONCURRENCY_OVERRIDE:-1 2 4 8 16 32 64})
# python-service loads every tier in docker-compose.yml's FEATURE_TIERS whatever this run's
# targets; keep in sync with that value.
EXPECTED_TIERS="5,10,20,28"
# Keep in sync with docker-compose.yml's THREAD_LIMITER_TOKENS default.
EXPECTED_THREAD_LIMITER_TOKENS="40"
# Highest level in CONCURRENCY_LEVELS: E2's max-VUs warm-up pass and the Java pool size.
MAX_VUS=0
for _lvl in "${CONCURRENCY_LEVELS[@]}"; do
  if [ "$_lvl" -gt "$MAX_VUS" ]; then MAX_VUS="$_lvl"; fi
done
BASELINE_ITERATIONS="${BASELINE_ITERATIONS_OVERRIDE:-500}"
# Fixed iterations per VU for levels outside CALIB_AFFECTED_LEVELS (1/2/4 by default),
# where too few VUs are in flight for the end-of-cell taper to matter; the other levels are
# duration-targeted (calibrate_target()). Equal to BASELINE_ITERATIONS, so these cells have
# at least the baseline's per-target sample size and comparable between-rep noise.
SCAN_ITERATIONS_PER_VU="${SCAN_ITERATIONS_PER_VU_OVERRIDE:-500}"

# Duration-targeted cells. per-vu-iterations runs each VU to its own count, so VUs finish at
# slightly different times and concurrency tapers off at the end of a cell. The taper lasts
# roughly the same time whatever the cell length, so CALIB_AFFECTED_LEVELS get iteration
# counts sized for about CALIB_TARGET_DURATION_S from the target's own throughput, keeping
# the taper a small tail. Counts are derived once per target before the scan reps
# (calibrate_scan_targets()) and reused by every rep, so each rep of a cell runs the same
# workload; throughput drift between reps only moves the cell's duration.
CALIB_VUS=16
CALIB_ITER_PER_VU=2000
CALIB_TARGET_DURATION_S=60
CALIB_AFFECTED_LEVELS="8 16 32 64"
declare -A CALIB_ITERATIONS_PER_VU
# "<target>:<vus>" -> iterations per VU, filled by calibrate_scan_targets().
declare -A CALIB_CACHE

# The metrics the analysis reads; dropping the rest of k6's output roughly halves disk use
# and analyze-results.py's peak memory. java_execution_time_ms is kept so the client-side
# remainder (http_req_duration minus it) can be computed.
KEEP_METRICS="http_req_duration,http_req_blocked,dropped_iterations,request_http_error,request_timeout_error,python_parsing_time_ms,python_thread_dispatch_time_ms,python_computation_time_ms,python_dataframe_construction_time_ms,python_model_inference_time_ms,python_compute_stall_time_ms,python_serialization_time_ms,python_total_time_ms,java_estimated_bridge_overhead_ms,java_execution_time_ms"
# Unset by default: converge_warmup drives warm-up.js in timed chunks under the gate. Set
# (e.g. by the smoke test), converge_warmup runs one fixed-iteration pass with no gate, so a
# reduced run is not dominated by its warm-up. Applies to the baseline and default-VUs scan
# passes; the max-VUs pass has its own overrides below.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"
WARMUP_MAX_DURATION_S_OVERRIDE="${WARMUP_MAX_DURATION_S_OVERRIDE:-}"

# ITERATIONS_PER_TARGET is a total split across VUs, so the max-VUs pass gets far fewer
# iterations per VU from the same value; a separate override avoids inflating the 5-VU
# passes to suit it. Falls back to the shared override when unset.
WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE:-$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}"
WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE="${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE:-$WARMUP_MAX_DURATION_S_OVERRIDE}"

# Warm-up env args for the baseline and default-VUs scan passes, scoped to this run's TARGETS.
WARMUP_ENV_ARGS=("WARMUP_TARGETS=${TARGETS[*]}")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAX_DURATION_S_OVERRIDE}")
fi

# Env args for the max-VUs pass: its own budget, same target scoping.
WARMUP_MAXVUS_ENV_ARGS=("WARMUP_TARGETS=${TARGETS[*]}")
if [ -n "$WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_MAXVUS_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
if [ -n "$WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE" ]; then
  WARMUP_MAXVUS_ENV_ARGS+=("WARMUP_MAX_DURATION_S=${WARMUP_MAXVUS_MAX_DURATION_S_OVERRIDE}")
fi
COOLDOWN_S=10
# ACPI/DPTF thermal negotiation does not complete on every platform, leaving the OS without
# platform thermal control. check_thermal_safety() (lib/thermal.sh) reads /sys/class/thermal
# directly, so a long pinned run pauses or aborts instead of hard-hanging the host.
THERMAL_WARN_C="${THERMAL_WARN_C_OVERRIDE:-90}"
THERMAL_CRIT_C="${THERMAL_CRIT_C_OVERRIDE:-95}"
THERMAL_COOLDOWN_S="${THERMAL_COOLDOWN_S_OVERRIDE:-60}"
MAX_THERMAL_COOLDOWNS="${MAX_THERMAL_COOLDOWNS_OVERRIDE:-2}"
# Rounds beyond MAX_THERMAL_COOLDOWNS are only granted while still cooling
# (check_thermal_safety), so this bounds the worst case rather than setting the
# common one.
THERMAL_MAX_COOLDOWNS_EXTENDED="${THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE:-10}"
# 7 vs 7 reps puts the smallest two-sided Mann-Whitney p-value on rep means at
# 2/C(14,7) = 0.00058, or 0.0029 after Holm correction across the five adjacent-target
# comparisons. 5 vs 5 gives 0.0079 (0.0397 corrected), with no margin for one noisy rep.
# Fewer than 7 is for pipeline checks such as the smoke test, not for analysis.
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

# Java's outbound pool to python-service (docker-compose.yml): 2x this run's peak VUs, so a
# wait for a free connection never lands inside the AI call round trip.
export PYTHON_SERVICE_MAX_CONNECTIONS=$((MAX_VUS * 2))

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
  # Pulled here when absent, so a host's first run records the digest too.
  docker image inspect "${k6_image:-grafana/k6}" >/dev/null 2>&1 \
    || docker compose -f "$COMPOSE_FILE" --profile loadgen pull -q k6 >/dev/null 2>&1 || true
  k6_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${k6_image:-grafana/k6}" 2>/dev/null \
    || echo "unknown (image not pulled yet)")

  local git_commit git_dirty fingerprint
  if command -v git >/dev/null 2>&1 && git -C .. rev-parse HEAD >/dev/null 2>&1; then
    git_commit=$(git -C .. rev-parse HEAD)
    if [ -n "$(git -C .. status --porcelain 2>/dev/null)" ]; then
      git_dirty="true"
    else
      git_dirty="false"
    fi
    fingerprint=$(measurement_fingerprint ..)
  else
    git_commit="unknown"
    git_dirty="unknown"
    fingerprint="unknown (not a git checkout)"
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

  # Opening snapshot only; record_env_sample() traces both ends of every rep to
  # env_trace_log.txt, which is what catches mid-run throttling.
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

  # From the resolved config, so PYTHON_CPUSET/JAVA_CPUSET/K6_CPUSET overrides apply. The
  # logical-CPU counts are summed into total_pinned_cores, recorded beside cpu_count (not
  # checked against it).
  local py_cpuset java_cpuset k6_cpuset
  py_cpuset=$(compose_service_value "python-service" cpuset)
  java_cpuset=$(compose_service_value "transaction-service" cpuset)
  k6_cpuset=$(compose_service_value "k6" cpuset)

  local py_cores java_cores k6_cores total_pinned_cores
  py_cores=$(count_cpuset_cores "${py_cpuset:-}")
  java_cores=$(count_cpuset_cores "${java_cpuset:-}")
  k6_cores=$(count_cpuset_cores "${k6_cpuset:-}")
  total_pinned_cores=$((py_cores + java_cores + k6_cores))

  local py_quota java_quota k6_quota uvicorn_workers
  py_quota=$(compose_service_value "python-service" cpus)
  java_quota=$(compose_service_value "transaction-service" cpus)
  k6_quota=$(compose_service_value "k6" cpus)
  uvicorn_workers=$(compose_service_value "python-service" UVICORN_WORKERS)

  # Aborts before any container starts if the three cpusets share physical cores with each
  # other, or if any of them owns only part of a physical core on this host.
  verify_smt_isolation "${py_cpuset:-}" "${java_cpuset:-}" "${k6_cpuset:-}"
  verify_service_cpuset "startup" "python-service" "${py_cpuset:-}" "$py_quota"
  verify_service_cpuset "startup" "transaction-service" "${java_cpuset:-}" "$java_quota"
  verify_service_cpuset "startup" "k6" "${k6_cpuset:-}" "$k6_quota"

  cat > "$METADATA_FILE" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "timestamp_utc": "$(json_escape "$timestamp")",
  "hostname": "$(json_escape "$(uname -n 2>/dev/null || echo unknown)")",
  "machine_id_hash": "$(machine_id_hash)",
  "host_uname": "$(json_escape "$host_uname")",
  "wsl2_detected": "${IS_WSL2}",
  "docker_version": "$(json_escape "$docker_version")",
  "docker_compose_version": "$(json_escape "$compose_version")",
  "k6_image": "$(json_escape "${k6_image:-unknown}")",
  "k6_image_digest": "$(json_escape "$k6_digest")",
  "git_commit": "$(json_escape "$git_commit")",
  "git_dirty": "$(json_escape "$git_dirty")",
  "measurement_fingerprint": "$(json_escape "$fingerprint")",
  "cpu_model": "$(json_escape "$cpu_model")",
  "cpu_count": "$(json_escape "$cpu_count")",
  "cpu_governor_at_start": "$(json_escape "$cpu_governor")",
  "cpu_freq_khz_at_start": "$(json_escape "$cpu_freq_khz")",
  "total_mem_kb": "$(json_escape "$total_mem_kb")",
  "host_provenance": $(host_provenance_json),
  "power_state": $(power_state_json "$REQUIRED_TURBO" "$POWER_STATE_AT_START"),
  "jvm_pinned_options": "$(json_escape "$(jvm_pinned_options)")",
  "cores_used_by_suite": {
    "python_service_cpuset": "$(json_escape "${py_cpuset:-unknown}")",
    "python_service_cores": ${py_cores},
    "transaction_service_cpuset": "$(json_escape "${java_cpuset:-unknown}")",
    "transaction_service_cores": ${java_cores},
    "k6_cpuset": "$(json_escape "${k6_cpuset:-unknown}")",
    "k6_cores": ${k6_cores},
    "python_service_cpus_quota": "$(json_escape "${py_quota:-unknown}")",
    "transaction_service_cpus_quota": "$(json_escape "${java_quota:-unknown}")",
    "k6_cpus_quota": "$(json_escape "${k6_quota:-unknown}")",
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
    "uvicorn_workers": "$(json_escape "${uvicorn_workers:-unknown}")",
    "thread_limiter_tokens": ${EXPECTED_THREAD_LIMITER_TOKENS},
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
      "max_cooldowns": ${MAX_THERMAL_COOLDOWNS},
      "max_cooldowns_extended": ${THERMAL_MAX_COOLDOWNS_EXTENDED}
    }
  }
}
EOF

  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} (pinned: ${total_pinned_cores}) governor=${cpu_governor} freq_khz=${cpu_freq_khz} git=${git_commit:0:12} wsl2=${IS_WSL2}"
  echo "  [metadata] $(host_provenance_line)"
}

# Logs an invalidating condition to the failures log, tears the stack down and exits 1;
# the analysis would reject the run anyway.
abort_suite() {
  local label="$1"; shift
  local reason="$*"  # join remaining args -- callers pass the message across multiple lines
  # >&2 on every line: some callers (e.g. jvm_container()) run inside $( ), which would
  # otherwise capture tee's stdout copy instead of letting it reach the console.
  echo "" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] ${label}: ${reason}" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] Aborting suite. No results were written for this rep. Prior reps" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] already on disk in ${RESULTS_DIR} are unaffected and can be kept," | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] but this suite invocation is incomplete -- fix the cause and" | tee -a "$FAILURES_LOG" >&2
  echo "  [FATAL] re-run run-suite.sh from the beginning." | tee -a "$FAILURES_LOG" >&2
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

# Measures the target's throughput X at CALIB_VUS ((N-1)/span of HTTP 200 completions) and
# sets CALIB_ITERATIONS_PER_VU[V] = max(1, round(X * CALIB_TARGET_DURATION_S / V)) for each
# CALIB_AFFECTED_LEVELS V. Throughput is roughly flat across these levels within a target
# but differs widely between targets, so no single count gives every target the same
# duration.
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
  # Cleared first: the derivation runs in a process substitution whose exit status is
  # lost, so a derivation that yields no rows must not leave the previous target's counts.
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

# Derives every target's duration-targeted counts once, on a stack prepared like a scan rep
# (restart, guards, both gated warm-up passes) that runs no measured cell. Doing it inside a
# rep would give that rep a load history the others lack; doing it every rep would give
# each rep of a cell a different workload. Skipped when no scan level is affected.
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
  check_power_state "scan calibration"
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

capture_run_metadata
SERVICE_CPUSETS="python=$(compose_service_value python-service cpuset) java=$(compose_service_value transaction-service cpuset) k6=$(compose_service_value k6 cpuset)"
PINNED_CPUS="$(compose_service_value python-service cpuset),$(compose_service_value transaction-service cpuset),$(compose_service_value k6 cpuset)"

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  record_env_sample "baseline_rep${rep}_start"
  check_power_state "baseline rep=${rep}"
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

  # Fresh target order per rep.
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
  check_power_state "scan rep=${rep}"
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

  # Second warm-up pass at the scan's peak VUs (pool growth, thread creation); its own
  # file, so table0 reports it separately.
  echo "[*] Warming up JIT / connection pools (MAX_VUS=${MAX_VUS})..."
  converge_warmup "warmup_scan_maxvus_rep${rep}" "${WARMUP_MAXVUS_ENV_ARGS[@]}" WARMUP_VUS="$MAX_VUS" "REP=${rep}"
  sleep "$COOLDOWN_S"

  # Target and concurrency order shuffled independently per rep, so within-rep drift
  # falls randomly across targets and levels.
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

rmdir "$RAW_RESULTS_DIR" 2>/dev/null || true
echo "[+] Suite complete. Results in ${RESULTS_DIR}/"
echo "    Per-rep cell order logged to ${ORDER_LOG}"
echo "    Connection-to-worker placement per cell logged to ${PLACEMENT_LOG}"
echo "    Host/toolchain fingerprint (incl. physical-core isolation) logged to ${METADATA_FILE}"
echo "    CPU pinning, SMT topology and thread-env checks logged to ${CPU_PIN_LOG}"
echo "    Per-rep governor/frequency/temperature and per-cell thermal and clock samples logged to ${ENV_TRACE_LOG}"
echo "    CPU power state (checked at every cell edge) recorded in ${METADATA_FILE}"
echo "    Warm-up JSON output (for post-hoc convergence check) saved as warmup_baseline_rep*.json.gz,"
echo "    warmup_scan_rep*.json.gz (default VUS), and warmup_scan_maxvus_rep*.json.gz (VUS=${MAX_VUS})"
echo "    'calibration' target included alongside mock/5/10/20/28 -- isolates instrumentation overhead"
echo "    Calibration pass (calib_*.json.gz, not read by analyze-results.py): the iteration counts"
echo "    every scan rep ran with are logged to ${CALIB_LOG}"
# Refuses to report success for a run that wrote no cell.
_n_cells=$(find "$RESULTS_DIR" -maxdepth 1 \( -name 'baseline_*.json.gz' -o -name 'scan_*.json.gz' \) 2>/dev/null | wc -l)
if [ "$_n_cells" -eq 0 ]; then
  abort_suite "[suite]" "no measurement cells were executed -- check TARGETS_OVERRIDE," \
    "CONCURRENCY_OVERRIDE and REPS_*_OVERRIDE. Not reporting this run as successful."
fi
echo "    No cell failures -- every rep passed cpu-pin and tier verification."
echo "    Run: ../analysis/venv/bin/python3 ../analysis/analyze-results.py"