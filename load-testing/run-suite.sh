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
# Keep in sync with docker-compose.yml's THREAD_LIMITER_TOKENS default.
EXPECTED_THREAD_LIMITER_TOKENS="40"
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

# Command substitution in a for-list is not an errexit context, so integer overrides must
# be validated explicitly before use.
for _intvar in REPS_BASELINE REPS_SCAN BASELINE_ITERATIONS SCAN_ITERATIONS_PER_VU; do
  if ! [[ "${!_intvar}" =~ ^[0-9]+$ ]] || [ "${!_intvar}" -lt 1 ]; then
    echo "[!] ${_intvar} must be a positive integer, got '${!_intvar}'." >&2
    exit 1
  fi
done
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

  # Resolve the cpuset each service is actually configured with (respects
  # PYTHON_CPUSET overrides, though run-suite.sh never sets one) and sum
  # cores pinned across the stack, to verify against cpu_count above.
  local resolved_config
  resolved_config=$(docker compose -f "$COMPOSE_FILE" --profile loadgen config 2>/dev/null || echo "")

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
  "k6_image": "$(json_escape "${k6_image:-unknown}")",
  "k6_image_digest": "$(json_escape "$k6_digest")",
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

# Samples governor and per-core frequency at a named point in the run.
record_env_sample() {
  local governor freqs
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
  freqs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | paste -sd, - || true)
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
      "(derived from requested cpuset ${java_requested}). availableProcessors() sizes Reactor Netty's" \
      "event-loop pool (max(availableProcessors(), 4)), ForkJoinPool.commonPool, the G1 worker threads" \
      "and the JIT compiler threads -- all of them would be sized off the wrong core count for this rep."
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

  # Pins BLAS/OpenMP layers to 1 thread alongside n_jobs=1 for true single-threaded inference.
  # Comma-delimited match: a bare substring match on *OMP_NUM_THREADS=1* also accepts 10, 16,
  # 100, 1024. All four variables are asserted, per the README.
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
  local expected_workers="${UVICORN_WORKERS:-3}"
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
    if not isinstance(verified, dict) or not verified:
        print("unreadable", d.get("workerPid", ""))
    else:
        failed = [tier for tier, ok in verified.items() if ok is not True and ok is not None]
        print(("failed:" + ",".join(failed) if failed else "ok"), d.get("workerPid", ""))
') || sample="unreadable "
    runtime_state="${sample%% *}"
    pid="${sample##* }"

    if [ "$runtime_state" = "unreadable" ]; then
      abort_suite "[tier-runtime] ${label}" "could not read nJobsRuntimeVerified from python-service's /health."
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
    echo "  [tier-runtime] ${label}: WARN -- only ${n_seen} of ${expected_workers} workers answered /health" \
         "across ${attempts} polls; the others are unverified for this rep." >&2
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
    # Not written to FAILURES_LOG: a missing GC log leaves that rep out of the GC
    # table but does not invalidate its latency data, and any entry in that log
    # makes analyze-results.py refuse the whole dataset.
    echo "  [!] No GC log found at ${src} for ${label}; GC overhead is unreported for this rep." >&2
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
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" "REP=${rep}" -- --out "json=/results/warmup_baseline_rep${rep}.json"
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
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" "REP=${rep}" -- --out "json=/results/warmup_scan_rep${rep}.json"
  verify_tiers_runtime "scan rep=${rep}"
  sleep "$COOLDOWN_S"

  # Matches warm-up concurrency to the scan's peak VUS; separate output
  # file so table0's convergence check can report on it distinctly.
  echo "[*] Warming up JIT / connection pools (MAX_VUS=${MAX_VUS})..."
  k6_run warm-up.js "${WARMUP_ENV_ARGS[@]}" WARMUP_VUS="$MAX_VUS" "REP=${rep}" -- \
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
# Guards against an empty run: "every rep passed" below is vacuously true if no cell ran.
_n_cells=$(find "$RESULTS_DIR" -maxdepth 1 -name 'baseline_*.json' -o -maxdepth 1 -name 'scan_*.json' 2>/dev/null | wc -l)
if [ "$_n_cells" -eq 0 ]; then
  abort_suite "[suite]" "no measurement cells were executed -- check TARGETS_OVERRIDE," \
    "CONCURRENCY_OVERRIDE and REPS_*_OVERRIDE. Not reporting this run as successful."
fi
echo "    No cell failures -- every rep passed cpu-pin and tier verification."
echo "    Run: ../analysis/venv/bin/python3 ../analysis/analyze-results.py"