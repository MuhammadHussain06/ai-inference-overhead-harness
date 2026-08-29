#!/usr/bin/env bash
set -euo pipefail

# Orchestrates empirical load tests across clean-slate stack restarts.
#
# Isolation & Controls:
#   - Isolates session noise (JIT, GC, OS) via per-rep stack restarts.
#   - Randomizes execution order per rep to prevent drift (logged to run_order_log.txt).
#   - Captures system provenance to run_metadata.json for traceability.
#   - Verifies runtime container cgroup cpusets and JVM thread-pool detection via
#     `docker inspect` per rep (logged to cpu_pin_check_log.txt).
#
# Suite Execution:
#   - Clean-slate stack restarts per rep; sequential cell runs within reps.
#   - Rep counts: Baseline = REPS_BASELINE | Concurrency Scan = REPS_SCAN.
#   - Depends on APP_DB_SAVE_ENABLED=false configured in docker-compose.yml.

# Anchor execution directory to the script's location for path stability.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Preflight: fail fast before any containers are touched.
# k6 runs containerized (see the `k6` service in docker-compose.yml),
# pinned to its own cpuset, separate from the services under test.
for _req_cmd in docker curl shuf; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR" "$RESULTS_DIR/gc-logs"
ORDER_LOG="${RESULTS_DIR}/run_order_log.txt"
: > "$ORDER_LOG"   # truncate/create fresh each suite run
METADATA_FILE="${RESULTS_DIR}/run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/run_failures_log.txt"
: > "$FAILURES_LOG"   # truncate/create fresh each suite run
CPU_PIN_LOG="${RESULTS_DIR}/cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"   # truncate/create fresh each suite run

TARGETS=(mock calibration 5 10 20 28)
CONCURRENCY_LEVELS=(1 2 4 8 16 32 64)
# Derived from CONCURRENCY_LEVELS; used by E2's max-VUS warm-up pass below.
MAX_VUS=0
for _lvl in "${CONCURRENCY_LEVELS[@]}"; do
  if [ "$_lvl" -gt "$MAX_VUS" ]; then MAX_VUS="$_lvl"; fi
done
BASELINE_ITERATIONS=500
SCAN_ITERATIONS_PER_VU=100
COOLDOWN_S=10
REPS_BASELINE=5
# n=5 vs 5 keeps the minimum achievable two-sided Mann-Whitney p-value
# (0.0079) below alpha=0.05, matching REPS_BASELINE's power for table5/table6.
REPS_SCAN=5


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

  # Single snapshot at capture time, not a per-rep trace -- can flag a rep as
  # suspect but can't catch mid-run throttling under sustained load.
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

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "$(json_escape "$timestamp")",
  "host_uname": "$(json_escape "$host_uname")",
  "docker_version": "$(json_escape "$docker_version")",
  "docker_compose_version": "$(json_escape "$compose_version")",
  "git_commit": "$(json_escape "$git_commit")",
  "git_dirty": "$(json_escape "$git_dirty")",
  "cpu_model": "$(json_escape "$cpu_model")",
  "cpu_count": "$(json_escape "$cpu_count")",
  "cpu_governor_at_start": "$(json_escape "$cpu_governor")",
  "cpu_freq_khz_at_start": "$(json_escape "$cpu_freq_khz")",
  "total_mem_kb": "$(json_escape "$total_mem_kb")",
  "suite_config": {
    "targets": [$(printf '"%s",' "${TARGETS[@]}" | sed 's/,$//')],
    "concurrency_levels": [$(printf '%s,' "${CONCURRENCY_LEVELS[@]}" | sed 's/,$//')],
    "max_vus": ${MAX_VUS},
    "scan_warmup_includes_max_vus_pass": true,
    "baseline_iterations": ${BASELINE_ITERATIONS},
    "scan_iterations_per_vu": ${SCAN_ITERATIONS_PER_VU},
    "cooldown_s": ${COOLDOWN_S},
    "reps_baseline": ${REPS_BASELINE},
    "reps_scan": ${REPS_SCAN}
  }
}
EOF

  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} governor=${cpu_governor} freq_khz=${cpu_freq_khz} git=${git_commit:0:12}"
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

# Reads the cpuset a container was actually assigned by the kernel, not what
# it was configured with. Tries cgroup v2 first, falls back to v1.
read_live_cpuset() {
  local container="$1"
  docker exec "$container" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}


# Aborts the suite: a rep with unverified CPU pinning must not produce k6
# output that gets pooled with clean reps. Tears the stack down and exits
# before that rep's k6 cells run.
abort_pin_failure() {
  local label="$1"; shift
  local reason="$*"  # join remaining args -- callers pass the message across multiple lines
  echo "" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] [cpu-pin] ${label}: ${reason}" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] Aborting suite -- CPU pinning could not be verified for this rep." | tee -a "$FAILURES_LOG"
  echo "  [FATAL] No results were written for this rep. Fix the host/Docker cgroup" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] setup (see README CPU pinning caveat) and re-run run-suite.sh from" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] the beginning -- prior reps already on disk in ${RESULTS_DIR} were" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] pin-verified and can be kept, but this suite invocation is incomplete." | tee -a "$FAILURES_LOG"
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

verify_cpu_pinning() {
  local label="$1"
  local py_container java_container
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")

  if [ -z "$py_container" ] || [ -z "$java_container" ]; then
    abort_pin_failure "$label" "could not resolve container IDs -- cannot verify pinning at all."
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
    abort_pin_failure "$label" "could not read a live cgroup cpuset -- pinning is unverifiable on this host."
  elif [ "$py_live" != "$py_requested" ] || [ "$java_live" != "$java_requested" ]; then
    abort_pin_failure "$label" "live cgroup cpuset (python=${py_live} java=${java_live}) does not match" \
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
    abort_pin_failure "$label" "could not read the JVM-reported Effective CPU Count -- Netty event-loop" \
      "sizing is unverifiable for this rep."
  elif [ -z "$expected_java_cpus" ] || [ "$expected_java_cpus" = "0" ]; then
    abort_pin_failure "$label" "could not derive an expected core count from the requested cpuset" \
      "(${java_requested:-EMPTY}) -- cannot verify JVM core detection for this rep."
  elif [ "$java_cpus" != "$expected_java_cpus" ]; then
    abort_pin_failure "$label" "JVM reports ${java_cpus} effective CPUs, expected ${expected_java_cpus}" \
      "(derived from requested cpuset ${java_requested}) -- Netty's event-loop thread count" \
      "(availableProcessors() * 2 by default) would be sized off the wrong core count for this rep."
  fi

  # Verifies the k6 container's own cpuset, matching the compose file's
  # hardcoded value.
  local k6_expected="6-7"
  local k6_live
  k6_live=$(docker compose -f "$COMPOSE_FILE" --profile loadgen run --rm -T --entrypoint sh k6 \
    -c 'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo "")
  echo "  [cpu-pin] ${label}: k6 live(${k6_live:-EMPTY}) expected(${k6_expected})"
  echo "cpu_pin_check label=${label} k6_live=${k6_live:-EMPTY} k6_expected=${k6_expected}" >> "$CPU_PIN_LOG"
  if [ -z "$k6_live" ]; then
    abort_pin_failure "$label" "could not read a live cgroup cpuset for the k6 container -- k6's" \
      "own core isolation is unverifiable on this host."
  elif [ "$k6_live" != "$k6_expected" ]; then
    abort_pin_failure "$label" "k6's live cgroup cpuset (${k6_live}) does not match the requested" \
      "cpuset (${k6_expected}) -- k6 core isolation was not honored on this Docker/cgroup driver version."
  fi

  echo "  [cpu-pin] ${label}: OK -- pinning verified, proceeding."
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

# Flags a cell if either container was OOM-killed during it.
check_oom_killed() {
  local label="$1"
  local py_container java_container py_oom java_oom
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  py_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$py_container" 2>/dev/null || echo "unknown")
  java_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$java_container" 2>/dev/null || echo "unknown")
  if [ "$py_oom" = "true" ] || [ "$java_oom" = "true" ]; then
    echo "  [!] OOM-killed during ${label}: python=${py_oom} java=${java_oom}" | tee -a "$FAILURES_LOG"
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

run_cell() {
  local label="$1"
  shift
  if ! "$@"; then
    echo "[!] FAILED: ${label}" | tee -a "$FAILURES_LOG"
  fi
  check_oom_killed "$label"
}

capture_run_metadata

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "baseline rep=${rep}"
  echo "[*] Warming up JIT / connection pools..."
  k6_run warm-up.js -- --out "json=/results/warmup_baseline_rep${rep}.json"
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
  archive_gc_log "baseline_rep${rep}"
done

echo "[*] E2: concurrency scan x ${REPS_SCAN} independent repetitions"
for rep in $(seq 1 "$REPS_SCAN"); do
  echo "[*] --- Scan repetition ${rep}/${REPS_SCAN} ---"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "scan rep=${rep}"
  echo "[*] Warming up JIT / connection pools (default VUS)..."
  k6_run warm-up.js -- --out "json=/results/warmup_scan_rep${rep}.json"
  sleep "$COOLDOWN_S"

  # Matches warm-up concurrency to the scan's peak VUS; separate output
  # file so table0's convergence check can report on it distinctly.
  echo "[*] Warming up JIT / connection pools (MAX_VUS=${MAX_VUS})..."
  k6_run warm-up.js WARMUP_VUS="$MAX_VUS" -- \
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
  archive_gc_log "scan_rep${rep}"
done

echo "[+] Suite complete. Raw results in ${RESULTS_DIR}/"
echo "    Per-rep cell order logged to ${ORDER_LOG}"
echo "    Host/toolchain fingerprint (incl. CPU governor/freq snapshot) logged to ${METADATA_FILE}"
echo "    CPU pinning verification (per-rep cgroup check) logged to ${CPU_PIN_LOG}"
echo "    Warm-up JSON output (for post-hoc convergence check) saved as warmup_baseline_rep*.json,"
echo "    warmup_scan_rep*.json (default VUS), and warmup_scan_maxvus_rep*.json (VUS=${MAX_VUS})"
echo "    'calibration' target included alongside mock/5/10/20/28 -- isolates instrumentation overhead"
# Reaching this point guarantees all completed reps passed CPU pin verification,
# as empty cpuset failures trigger immediate suite aborts via abort_pin_failure.
if [ -s "$FAILURES_LOG" ]; then
  echo "    [!] Some cells failed and were skipped -- see ${FAILURES_LOG}"
  echo "        Re-run just those cells manually before treating results as complete."
else
  echo "    No cell failures logged."
fi
echo "    Run: python3 ../analysis/analyze-results.py"