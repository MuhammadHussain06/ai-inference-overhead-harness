#!/usr/bin/env bash
set -euo pipefail

# Orchestrates clean-slate stack restarts, randomized execution order, system provenance logging,
# and verification of CPU pinning, thread caps (n_jobs, BLAS/OpenMP), and CPU governor frequencies.

# Anchor execution directory to the script's location for path stability.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Preflight: fail fast before any containers are touched.
# k6 runs containerized (see the `k6` service in docker-compose.yml),
# pinned to its own cpuset, separate from the services under test.
for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

# Warns on WSL2: cgroup cpuset checks pass, but Hyper-V host core migration is unobservable.
# Non-blocking; flags warning and records status in run_metadata.json.
IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- physical-core pinning is not guaranteed even when" >&2
  echo "    verify_cpu_pinning() reports OK (see README Limitations). Recorded" >&2
  echo "    in run_metadata.json for this run." >&2
fi

# Set by verify_smt_isolation() during metadata capture; recorded in run_metadata.json.
SMT_TOPOLOGY_STATUS="not checked"

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR" "$RESULTS_DIR/gc-logs"

# Timestamp-archives prior cell logs, JSON metrics, and GC output outside
# of RESULTS_DIR to prevent non-recursive analysis glob collisions.
if compgen -G "${RESULTS_DIR}/*.json" > /dev/null 2>&1 || [ -f "${RESULTS_DIR}/run_order_log.txt" ]; then
  ARCHIVE_DIR="${RESULTS_DIR}/archive/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$ARCHIVE_DIR"
  find "$RESULTS_DIR" -maxdepth 1 -name '*.json' -exec mv {} "$ARCHIVE_DIR/" \;
  find "$RESULTS_DIR" -maxdepth 1 -name '*_log.txt' -exec mv {} "$ARCHIVE_DIR/" \;
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
: > "$FAILURES_LOG"   # truncate/create fresh each suite run
CPU_PIN_LOG="${RESULTS_DIR}/cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"   # truncate/create fresh each suite run
# Governor/frequency sampled at both ends of every rep, so mid-suite thermal
# throttling or a governor change can be attributed to a specific rep rather
# than inferred from a single snapshot taken before the run started.
ENV_TRACE_LOG="${RESULTS_DIR}/env_trace_log.txt"
: > "$ENV_TRACE_LOG"   # truncate/create fresh each suite run

TARGETS=(${TARGETS_OVERRIDE:-mock calibration 5 10 20 28})
CONCURRENCY_LEVELS=(${CONCURRENCY_OVERRIDE:-1 2 4 8 16 32 64})
# python-service always loads every tier in docker-compose.yml's FEATURE_TIERS,
# regardless of which subset of targets this invocation exercises -- keep in
# sync with docker-compose.yml's FEATURE_TIERS if that value ever changes.
EXPECTED_TIERS="5,10,20,28"
# Derived from CONCURRENCY_LEVELS; used by E2's max-VUS warm-up pass below.
MAX_VUS=0
for _lvl in "${CONCURRENCY_LEVELS[@]}"; do
  if [ "$_lvl" -gt "$MAX_VUS" ]; then MAX_VUS="$_lvl"; fi
done
BASELINE_ITERATIONS="${BASELINE_ITERATIONS_OVERRIDE:-500}"
SCAN_ITERATIONS_PER_VU="${SCAN_ITERATIONS_PER_VU_OVERRIDE:-100}"
# Unset by default -- warm-up.js's own 3000 default applies for the full suite.
# Set for a reduced-scale run (e.g. the smoke test) so warm-up doesn't dwarf it.
WARMUP_ITERATIONS_PER_TARGET_OVERRIDE="${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE:-}"

# Shared warm-up env args: WARMUP_TARGETS keeps warm-up scoped to this run's
# actual TARGETS (matters when TARGETS_OVERRIDE reduces it, e.g. the smoke
# test) instead of always warming all 6 targets regardless of what's being
# tested. WARMUP_ITERATIONS_PER_TARGET only passed if explicitly overridden,
# so the full suite keeps warm-up.js's own 3000 default untouched.
WARMUP_ENV_ARGS=("WARMUP_TARGETS=${TARGETS[*]}")
if [ -n "$WARMUP_ITERATIONS_PER_TARGET_OVERRIDE" ]; then
  WARMUP_ENV_ARGS+=("WARMUP_ITERATIONS_PER_TARGET=${WARMUP_ITERATIONS_PER_TARGET_OVERRIDE}")
fi
COOLDOWN_S=10
# n=7 vs 7 puts the minimum achievable two-sided Mann-Whitney p-value at
# 2/C(14,7) = 0.00058, which still clears alpha=0.05 after Holm correction
# across the five adjacent-tier comparisons (0.00058 x 5 = 0.0029). n=5 vs 5
# reaches only 0.0079, or 0.0397 corrected -- significant, but with no margin
# for a single noisy rep. Overriding below 7 (e.g. for a smoke test) is fine
# for a pipeline check, not for a rep count you intend to analyze for real.
REPS_BASELINE="${REPS_BASELINE_OVERRIDE:-7}"
REPS_SCAN="${REPS_SCAN_OVERRIDE:-7}"

# Sized off this run's own peak VUS so the Java outbound pool can never become
# the bottleneck being measured. Consumed by docker-compose.yml.
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

  # Resolve the cpuset each service is actually configured with (respects
  # PYTHON_CPUSET overrides, though run-suite.sh never sets one) and sum
  # cores pinned across the stack, to verify against cpu_count above.
  local resolved_config
  resolved_config=$(docker compose -f "$COMPOSE_FILE" config 2>/dev/null || echo "")

  extract_cpuset() {
    printf '%s\n' "$resolved_config" | awk -v svc="  ${1}:" '
      $0 == svc { in_svc=1; next }
      in_svc && /^  [a-zA-Z0-9_-]+:$/ { in_svc=0 }
      in_svc && /^ +cpuset:/ { sub(/^ +cpuset: */, ""); gsub(/"/, ""); print; exit }
    '
  }

  local py_cpuset java_cpuset k6_cpuset
  py_cpuset=$(extract_cpuset "python-service")
  java_cpuset=$(extract_cpuset "transaction-service")
  k6_cpuset=$(extract_cpuset "k6")

  local py_cores java_cores k6_cores total_pinned_cores
  py_cores=$(count_cpuset_cores "${py_cpuset:-}")
  java_cores=$(count_cpuset_cores "${java_cpuset:-}")
  k6_cores=$(count_cpuset_cores "${k6_cpuset:-}")
  total_pinned_cores=$((py_cores + java_cores + k6_cores))

  # Aborts before any container starts if the three cpusets share physical cores.
  verify_smt_isolation "${py_cpuset:-}" "${java_cpuset:-}" "${k6_cpuset:-}"

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "$(json_escape "$timestamp")",
  "host_uname": "$(json_escape "$host_uname")",
  "wsl2_detected": "${IS_WSL2}",
  "docker_version": "$(json_escape "$docker_version")",
  "docker_compose_version": "$(json_escape "$compose_version")",
  "git_commit": "$(json_escape "$git_commit")",
  "git_dirty": "$(json_escape "$git_dirty")",
  "cpu_model": "$(json_escape "$cpu_model")",
  "cpu_count": "$(json_escape "$cpu_count")",
  "cpu_governor_at_start": "$(json_escape "$cpu_governor")",
  "cpu_freq_khz_at_start": "$(json_escape "$cpu_freq_khz")",
  "total_mem_kb": "$(json_escape "$total_mem_kb")",
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
    "java_outbound_max_connections": ${PYTHON_SERVICE_MAX_CONNECTIONS}
  }
}
EOF

  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} (pinned: ${total_pinned_cores}) governor=${cpu_governor} freq_khz=${cpu_freq_khz} git=${git_commit:0:12} wsl2=${IS_WSL2}"
}

# Parses a Docker cpuset string (e.g., "3-5" or "0,2,4") to compute the target core
# count dynamically, ensuring JVM processor validation scales with configuration.
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
# Guarantees CPU pinning isolates hardware execution units between services.
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
    [ -n "$key" ] && echo "$key"
  done < <(expand_cpuset "$1") | sort -un | paste -sd, -
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

# Samples governor and per-core frequency at a named point in the run.
record_env_sample() {
  local governor freqs
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
  freqs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | paste -sd, -)
  echo "env_sample label=${1} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) governor=${governor} freqs_khz=${freqs:-unavailable}" \
    >> "$ENV_TRACE_LOG"
}

# Reads the cpuset a container was actually assigned by the kernel, not what
# it was configured with. Tries cgroup v2 first, falls back to v1.
read_live_cpuset() {
  local container="$1"
  docker exec "$container" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}


# Aborts the suite: a rep with unverified CPU pinning must not produce k6
# Any invalidating condition -- pinning, tier loading, or a cell failure --
# tears the stack down and exits rather than continuing to produce output
# that would just get rejected wholesale at analysis time anyway.
abort_suite() {
  local label="$1"; shift
  local reason="$*"  # join remaining args -- callers pass the message across multiple lines
  echo "" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] ${label}: ${reason}" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] Aborting suite. No results were written for this rep. Prior reps" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] already on disk in ${RESULTS_DIR} are unaffected and can be kept," | tee -a "$FAILURES_LOG"
  echo "  [FATAL] but this suite invocation is incomplete -- fix the cause and" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] re-run run-suite.sh from the beginning." | tee -a "$FAILURES_LOG"
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

  # Verify JVM cpuset detection. Reads "Effective CPU Count" from `-XshowSettings:system`
  # (JDK 10+), which populates Runtime.availableProcessors() to size Netty event loops.
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
      "(derived from requested cpuset ${java_requested}) -- Netty's event-loop thread count" \
      "(availableProcessors() * 2 by default) would be sized off the wrong core count for this rep."
  fi

  # Verifies the k6 container's own cpuset, matching the compose file's
  # hardcoded value.
  local k6_expected="10-11,14-15"
  local k6_live
  k6_live=$(docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T --entrypoint sh k6 \
    -c 'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo "")
  echo "  [cpu-pin] ${label}: k6 live(${k6_live:-EMPTY}) expected(${k6_expected})"
  echo "cpu_pin_check label=${label} k6_live=${k6_live:-EMPTY} k6_expected=${k6_expected}" >> "$CPU_PIN_LOG"
  if [ -z "$k6_live" ]; then
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
    print("true" if all(data.get("nJobsVerified", {}).values()) else "false")
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

  if [ "$loaded_tiers" != "$EXPECTED_TIERS" ]; then
    abort_suite "[tier-check] ${label}" "python-service's /health loadedTiers (${loaded_tiers:-EMPTY})" \
      "does not match expected (${EXPECTED_TIERS})."
  elif [ "$all_verified" != "true" ]; then
    abort_suite "[tier-check] ${label}" "python-service's /health nJobsVerified reports at least one" \
      "tier without n_jobs pinned to 1 -- single-threaded inference guarantee not met."
  fi

  # Pin BLAS/OpenMP layers to 1 thread alongside n_jobs=1 to guarantee true single-threaded inference for CPU pinning.
  case "$thread_env" in
    *OMP_NUM_THREADS=1*) ;;
    *) abort_suite "[tier-check] ${label}" "python-service reports OMP_NUM_THREADS not pinned to 1" \
         "(${thread_env:-EMPTY}) -- numeric libraries may spawn threads outside the measured cpuset." ;;
  esac
}

# Re-checks n_jobs post-warm-up to verify runtime concurrency setting per active test tier.
verify_tiers_runtime() {
  local label="$1"
  local runtime_state
  runtime_state=$(curl -s http://localhost:8000/health 2>/dev/null | python3 -c '
import json, sys
try:
    verified = json.load(sys.stdin).get("nJobsRuntimeVerified", {})
except Exception:
    print("unreadable")
else:
    failed = [tier for tier, ok in verified.items() if ok is False]
    print("failed:" + ",".join(failed) if failed else "ok")
')

  echo "  [tier-runtime] ${label}: ${runtime_state}"
  echo "cpu_pin_check label=${label} n_jobs_runtime=${runtime_state}" >> "$CPU_PIN_LOG"

  if [ "$runtime_state" = "unreadable" ]; then
    abort_suite "[tier-runtime] ${label}" "could not read nJobsRuntimeVerified from python-service's /health."
  elif [ "$runtime_state" != "ok" ]; then
    abort_suite "[tier-runtime] ${label}" "tier(s) reported n_jobs != 1 after serving inference" \
      "(${runtime_state}) -- the single-threaded guarantee held at load time but not at run time."
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
  echo "  [!] transaction-service did not become ready in time." >&2
  return 1
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

# Aborts the suite if either container was OOM-killed during the cell.
check_oom_killed() {
  local label="$1"
  local py_container java_container py_oom java_oom
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  py_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$py_container" 2>/dev/null || echo "unknown")
  java_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$java_container" 2>/dev/null || echo "unknown")
  if [ "$py_oom" = "true" ] || [ "$java_oom" = "true" ]; then
    abort_suite "[cell] ${label}" "OOM-killed: python=${py_oom} java=${java_oom}"
  fi
}

# Moves the JVM's GC log (continuously written to gc.log for the container's
# whole lifetime) to a rep-labeled file before the next restart_stack starts
# a fresh JVM and overwrites it. Call once per rep, after that rep's cells.
archive_gc_log() {
  local label="$1"
  local src="$RESULTS_DIR/gc-logs/gc.log"
  local dest="$RESULTS_DIR/gc-logs/gc_${label}.log"
  if [ -f "$src" ]; then
    mv "$src" "$dest"
  else
    echo "  [!] No GC log found at ${src} for ${label}" | tee -a "$FAILURES_LOG"
  fi
}

# Aborts the suite on the first cell failure -- no benefit to continuing
# once analyze-results.py will reject the whole run anyway.
run_cell() {
  local label="$1"
  shift
  if ! "$@"; then
    abort_suite "[cell] ${label}" "k6 exited non-zero."
  fi
  check_oom_killed "$label"
}

capture_run_metadata

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  record_env_sample "baseline_rep${rep}_start"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "baseline rep=${rep}"
  verify_tiers "baseline rep=${rep}"
  echo "[*] Warming up JIT / connection pools..."
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" -- --out "json=/results/warmup_baseline_rep${rep}.json"
  verify_tiers_runtime "baseline rep=${rep}"
  sleep "$COOLDOWN_S"

  # Independent per-rep shuffle of target order.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  echo "baseline rep=${rep} target_order=${TARGETS_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    echo "  -> target=${target} rep=${rep}"
    run_cell "baseline target=${target} rep=${rep}" \
      k6_run run-target.js \
      TARGET="$target" VUS=1 ITERATIONS="$BASELINE_ITERATIONS" PHASE=baseline REP="$rep" -- \
      --out "json=/results/baseline_${target}_rep${rep}.json"
    sleep "$COOLDOWN_S"
  done
  record_env_sample "baseline_rep${rep}_end"
  archive_gc_log "baseline_rep${rep}"
done

echo "[*] E2: concurrency scan x ${REPS_SCAN} independent repetitions"
for rep in $(seq 1 "$REPS_SCAN"); do
  echo "[*] --- Scan repetition ${rep}/${REPS_SCAN} ---"
  record_env_sample "scan_rep${rep}_start"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "scan rep=${rep}"
  verify_tiers "scan rep=${rep}"
  echo "[*] Warming up JIT / connection pools (default VUS)..."
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" -- --out "json=/results/warmup_scan_rep${rep}.json"
  verify_tiers_runtime "scan rep=${rep}"
  sleep "$COOLDOWN_S"

  # Matches warm-up concurrency to the scan's peak VUS; separate output
  # file so table0's convergence check can report on it distinctly.
  echo "[*] Warming up JIT / connection pools (MAX_VUS=${MAX_VUS})..."
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" WARMUP_VUS="$MAX_VUS" -- \
    --out "json=/results/warmup_scan_maxvus_rep${rep}.json"
  sleep "$COOLDOWN_S"

  # Randomizes target and concurrency order per rep (shuffled independently)
  # to decorrelate within-rep drift from individual test factors.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  read -ra CONCURRENCY_THIS_REP <<< "$(shuffled "${CONCURRENCY_LEVELS[@]}")"
  echo "scan rep=${rep} target_order=${TARGETS_THIS_REP[*]} concurrency_order=${CONCURRENCY_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"
  echo "  [order] concurrency levels this rep: ${CONCURRENCY_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    for vus in "${CONCURRENCY_THIS_REP[@]}"; do
      echo "  -> target=${target} vus=${vus} rep=${rep}"
      run_cell "scan target=${target} vus=${vus} rep=${rep}" \
        k6_run run-target.js \
        TARGET="$target" VUS="$vus" ITERATIONS_PER_VU="$SCAN_ITERATIONS_PER_VU" PHASE=scan REP="$rep" -- \
        --out "json=/results/scan_${target}_vus${vus}_rep${rep}.json"
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
echo "    Per-rep governor/frequency samples logged to ${ENV_TRACE_LOG}"
echo "    Warm-up JSON output (for post-hoc convergence check) saved as warmup_baseline_rep*.json,"
echo "    warmup_scan_rep*.json (default VUS), and warmup_scan_maxvus_rep*.json (VUS=${MAX_VUS})"
echo "    'calibration' target included alongside mock/5/10/20/28 -- isolates instrumentation overhead"
echo "    No cell failures -- every rep passed cpu-pin and tier verification."
echo "    Run: python3 ../analysis/analyze-results.py"