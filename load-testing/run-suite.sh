#!/usr/bin/env bash
set -euo pipefail

# Orchestrates empirical load tests across clean-slate stack restarts.
#
# Variance & Isolation:
#   - WITHIN-RUN  : Request noise in a single k6 run.
#   - BETWEEN-RUN : Session effects (JIT, GC, OS state) isolated via stack restarts.
#   - SHUFFLING   : Target/concurrency order randomized per rep to prevent drift.
#                   Execution sequence logged to run_order_log.txt.
#   - PROVENANCE  : Host/toolchain fingerprint captured once per suite run to
#                   run_metadata.json, so results are traceable to the exact
#                   environment that produced them.
#   - CPU PINNING : Verified (not assumed) once per rep via `docker inspect`
#                   against the running containers' actual cgroup cpuset,
#                   logged to cpu_pin_check_log.txt -- the compose file's
#                   `cpuset` directive states what was requested, this states
#                   what was actually applied.
#
# Suite Strategy:
#   - Clean-slate stack restart per rep; sequential cell runs within reps.
#   - Rep Counts: E1 (baseline) = REPS_BASELINE | E2 (concurrency scan) = REPS_SCAN.
#
# Prerequisite: Set APP_DB_SAVE_ENABLED=false in ../docker-compose.yml.

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

TARGETS=(mock 5 10 20 28)
CONCURRENCY_LEVELS=(1 2 4 8 16 32 64)
BASELINE_ITERATIONS=500
SCAN_ITERATIONS_PER_VU=100
COOLDOWN_S=10
REPS_BASELINE=5
REPS_SCAN=3


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

  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} git=${git_commit:0:12}"
}

# Verifies docker-compose.yml CPU pinning directly on running container cgroups rather
# than assuming the cpuset directive was honored, logging per rep to catch quiet driver overrides.
verify_cpu_pinning() {
  local label="$1"
  local py_container java_container py_cpuset java_cpuset
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")

  if [ -z "$py_container" ] || [ -z "$java_container" ]; then
    echo "  [!] [cpu-pin] could not resolve container IDs -- skipping verification for ${label}." | tee -a "$FAILURES_LOG"
    return
  fi

  py_cpuset=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$py_container" 2>/dev/null || echo "")
  java_cpuset=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$java_container" 2>/dev/null || echo "")

  echo "  [cpu-pin] ${label}: python-service=cpuset(${py_cpuset:-EMPTY}) transaction-service=cpuset(${java_cpuset:-EMPTY})"
  echo "cpu_pin_check label=${label} python_cpuset=${py_cpuset:-EMPTY} java_cpuset=${java_cpuset:-EMPTY}" >> "$CPU_PIN_LOG"

  if [ -z "$py_cpuset" ] || [ -z "$java_cpuset" ]; then
    echo "  [!] [cpu-pin] one or both containers report an EMPTY cpuset for ${label} -- pinning may not be" \
         "honored on this Docker/cgroup driver version; results from this rep should not be assumed" \
         "core-isolated. See README CPU pinning caveat." | tee -a "$FAILURES_LOG"
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
  k6 run warm-up.js
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
  k6 run warm-up.js
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
echo "    Host/toolchain fingerprint logged to ${METADATA_FILE}"
echo "    CPU pinning verification (per-rep cgroup check) logged to ${CPU_PIN_LOG}"
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