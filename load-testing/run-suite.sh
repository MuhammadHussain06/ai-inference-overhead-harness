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
for _req_cmd in docker curl shuf; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR"
ORDER_LOG="${RESULTS_DIR}/run_order_log.txt"
: > "$ORDER_LOG"   # truncate/create fresh each suite run
METADATA_FILE="${RESULTS_DIR}/run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/run_failures_log.txt"
: > "$FAILURES_LOG"   # truncate/create fresh each suite run
CPU_PIN_LOG="${RESULTS_DIR}/cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"   # truncate/create fresh each suite run

TARGETS=(mock calibration 5 10 20 28)
CONCURRENCY_LEVELS=(1 2 4 8 16 32 64)
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

 # Verify the JVM correctly detected cpuset limits, as Netty sizes event-loop
 # threads using Runtime.availableProcessors() based on cgroup auto-detection.
  local java_cpus
  java_cpus=$(docker exec "$java_container" sh -c \
    'java -XshowSettings:system -version 2>&1 | grep -i "available processors" | grep -o "[0-9]*"' \
    2>/dev/null || echo "")
  echo "  [cpu-pin] ${label}: JVM-reported available processors(${java_cpus:-EMPTY})"
  echo "cpu_pin_check label=${label} jvm_available_processors=${java_cpus:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ -z "$java_cpus" ]; then
    abort_pin_failure "$label" "could not read JVM-reported available processors -- Netty event-loop" \
      "sizing is unverifiable for this rep."
  elif [ "$java_cpus" != "3" ]; then
    abort_pin_failure "$label" "JVM reports ${java_cpus} available processors, expected 3 -- Netty's" \
      "event-loop thread count (availableProcessors() * 2 by default) would be sized off the wrong" \
      "core count for this rep."
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

run_cell() {
  local label="$1"
  shift
  if ! "$@"; then
    echo "[!] FAILED: ${label}" | tee -a "$FAILURES_LOG"
  fi
}

capture_run_metadata

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "baseline rep=${rep}"
  echo "[*] Warming up JIT / connection pools..."
  k6 run warm-up.js --out "json=${RESULTS_DIR}/warmup_baseline_rep${rep}.json"
  sleep "$COOLDOWN_S"

  # Independent per-rep shuffle of target order.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  echo "baseline rep=${rep} target_order=${TARGETS_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    echo "  -> target=${target} rep=${rep}"
    run_cell "baseline target=${target} rep=${rep}" \
      env TARGET="$target" VUS=1 ITERATIONS=$BASELINE_ITERATIONS PHASE=baseline REP="$rep" \
      k6 run run-target.js \
      --out "json=${RESULTS_DIR}/baseline_${target}_rep${rep}.json"
    sleep "$COOLDOWN_S"
  done
done

echo "[*] E2: concurrency scan x ${REPS_SCAN} independent repetitions"
for rep in $(seq 1 "$REPS_SCAN"); do
  echo "[*] --- Scan repetition ${rep}/${REPS_SCAN} ---"
  restart_stack
  wait_for_ready
  verify_cpu_pinning "scan rep=${rep}"
  echo "[*] Warming up JIT / connection pools..."
  k6 run warm-up.js --out "json=${RESULTS_DIR}/warmup_scan_rep${rep}.json"
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
        env TARGET="$target" VUS="$vus" ITERATIONS_PER_VU=$SCAN_ITERATIONS_PER_VU PHASE=scan REP="$rep" \
        k6 run run-target.js \
        --out "json=${RESULTS_DIR}/scan_${target}_vus${vus}_rep${rep}.json"
      sleep "$COOLDOWN_S"
    done
  done
done

echo "[+] Suite complete. Raw results in ${RESULTS_DIR}/"
echo "    Per-rep cell order logged to ${ORDER_LOG}"
echo "    Host/toolchain fingerprint (incl. CPU governor/freq snapshot) logged to ${METADATA_FILE}"
echo "    CPU pinning verification (per-rep cgroup check) logged to ${CPU_PIN_LOG}"
echo "    Warm-up JSON output (for post-hoc convergence check) saved as warmup_{baseline,scan}_rep*.json"
echo "    'calibration' target included alongside mock/5/10/20/28 -- isolates instrumentation overhead"
if grep -q "EMPTY" "$CPU_PIN_LOG" 2>/dev/null; then
  echo "    [!] One or more reps showed an EMPTY cpuset -- see ${CPU_PIN_LOG} and ${FAILURES_LOG}"
fi
if [ -s "$FAILURES_LOG" ]; then
  echo "    [!] Some cells failed and were skipped -- see ${FAILURES_LOG}"
  echo "        Re-run just those cells manually before treating results as complete."
else
  echo "    No cell failures logged."
fi
echo "    Run: python3 ../analysis/analyze-results.py"