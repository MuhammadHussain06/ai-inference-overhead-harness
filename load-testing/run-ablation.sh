#!/usr/bin/env bash
set -euo pipefail

# Isolates which mechanism drives Thread Dispatch time at high concurrency
# (figure5_decomposition_vs_concurrency), by varying one candidate cause at a
# time while holding the other two at a fixed control value. Fixed at
# TARGET=28, VUS=64 -- the cell where Thread Dispatch was largest.
#
# Arms (see README "Thread-dispatch mechanism ablation"):
#   thread_limiter : THREAD_LIMITER_TOKENS in {40, 64, 128} -- AnyIO's cap on
#                    concurrent run_in_threadpool() calls.
#   cpuset         : PYTHON_CPUSET in {0-2, 8-13, 8-15} (3/6/8 cores) -- the
#                    physical-core ceiling available to python-service. Uses
#                    cores 8+ instead of widening from 0-2, since 0-5/0-7
#                    would overlap transaction-service (3-5) and k6 (6-7).
#   workers        : UVICORN_WORKERS in {1, 2, 3} -- process count. Each
#                    worker gets its own interpreter (own GIL); this is the
#                    direct GIL test.
#
# Arms thread_limiter and cpuset fix UVICORN_WORKERS=1 so each isolates its
# own mechanism without a multi-process confound. This means their absolute
# Thread Dispatch numbers will NOT match figure5 (recorded at workers=3);
# only the workers=3 cell in the workers arm is directly comparable to it.
#
# Same clean-slate-per-rep methodology as run-suite.sh: independent restart,
# no shared warm state, cpu-pin and tier verification every rep.

cd "$(dirname "${BASH_SOURCE[0]}")"

for _req_cmd in docker curl shuf python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

IS_WSL2="false"
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL2="true"
  echo "[!] WSL2 detected -- see README Limitations on cpu-pin verification under WSL2." >&2
fi

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR"

# Separate log files from run-suite.sh's, so an ablation run never trips
# analyze-results.py's hard-fail-on-any-failures-log-entry check for the main
# suite's own dataset.
ORDER_LOG="${RESULTS_DIR}/ablation_run_order_log.txt"
: > "$ORDER_LOG"
METADATA_FILE="${RESULTS_DIR}/ablation_run_metadata.json"
FAILURES_LOG="${RESULTS_DIR}/ablation_run_failures_log.txt"
: > "$FAILURES_LOG"
CPU_PIN_LOG="${RESULTS_DIR}/ablation_cpu_pin_check_log.txt"
: > "$CPU_PIN_LOG"

ABLATION_TARGET="${ABLATION_TARGET_OVERRIDE:-28}"
ABLATION_VUS="${ABLATION_VUS_OVERRIDE:-64}"
ITERATIONS_PER_VU="${ABLATION_ITERATIONS_PER_VU_OVERRIDE:-100}"
REPS_ABLATION="${REPS_ABLATION_OVERRIDE:-5}"
COOLDOWN_S=10
ANYIO_DEFAULT_TOKENS=40

# arm:value:cpuset:cpus:workers:thread_limiter -- the fixed control setting
# for each arm, with one field swept per row. cpus is core count in cpuset.
CELLS=(
  "thread_limiter:40:0-2:3.0:1:40"
  "thread_limiter:64:0-2:3.0:1:64"
  "thread_limiter:128:0-2:3.0:1:128"
  "cpuset:0-2:0-2:3.0:1:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:8-13:8-13:6.0:1:${ANYIO_DEFAULT_TOKENS}"
  "cpuset:8-15:8-15:8.0:1:${ANYIO_DEFAULT_TOKENS}"
  "workers:1:0-2:3.0:1:${ANYIO_DEFAULT_TOKENS}"
  "workers:2:0-2:3.0:2:${ANYIO_DEFAULT_TOKENS}"
  "workers:3:0-2:3.0:3:${ANYIO_DEFAULT_TOKENS}"
)

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

  cat > "$METADATA_FILE" <<EOF
{
  "timestamp_utc": "${timestamp}",
  "wsl2_detected": "${IS_WSL2}",
  "git_commit": "${git_commit}",
  "git_dirty": "${git_dirty}",
  "cpu_model": "${cpu_model}",
  "cpu_count": "${cpu_count}",
  "total_mem_kb": "${total_mem_kb}",
  "ablation_config": {
    "target": "${ABLATION_TARGET}",
    "vus": ${ABLATION_VUS},
    "iterations_per_vu": ${ITERATIONS_PER_VU},
    "reps": ${REPS_ABLATION},
    "anyio_default_tokens": ${ANYIO_DEFAULT_TOKENS},
    "cells": [$(printf '"%s",' "${CELLS[@]}" | sed 's/,$//')]
  }
}
EOF
  echo "  [metadata] host=${cpu_model:-unknown} cores=${cpu_count} git=${git_commit:0:12} wsl2=${IS_WSL2}"
}

abort_suite() {
  local label="$1"; shift
  echo "" | tee -a "$FAILURES_LOG"
  echo "  [FATAL] ${label}: $*" | tee -a "$FAILURES_LOG"
  docker compose -f "$COMPOSE_FILE" down || true
  exit 1
}

read_live_cpuset() {
  docker exec "$1" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
}

# Trimmed from run-suite.sh's verify_cpu_pinning: python-service's cpuset
# varies per cell here, so this compares live-vs-requested only (still the
# check that matters -- whether the cgroup driver honored what was asked).
verify_cpu_pinning() {
  local label="$1"
  local py_container py_requested py_live
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  [ -z "$py_container" ] && abort_suite "[cpu-pin] ${label}" "could not resolve python-service container ID."
  py_requested=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$py_container" 2>/dev/null || echo "")
  py_live=$(read_live_cpuset "$py_container")
  echo "  [cpu-pin] ${label}: requested(${py_requested:-EMPTY}) live(${py_live:-EMPTY})"
  echo "cpu_pin_check label=${label} python_requested=${py_requested:-EMPTY} python_live=${py_live:-EMPTY}" >> "$CPU_PIN_LOG"
  if [ -z "$py_live" ] || [ "$py_live" != "$py_requested" ]; then
    abort_suite "[cpu-pin] ${label}" "live cpuset (${py_live:-EMPTY}) does not match requested (${py_requested:-EMPTY})."
  fi
}

verify_tiers_and_limiter() {
  local label="$1" expected_tokens="$2"
  local health_json loaded_tiers all_verified live_tokens
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
    print("true" if all(d.get("nJobsVerified", {}).values()) else "false")
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

  echo "  [health] ${label}: tiers(${loaded_tiers:-EMPTY}) n_jobs_verified(${all_verified}) thread_limiter_tokens(${live_tokens:-EMPTY} expected ${expected_tokens})"
  if [ "$loaded_tiers" != "5,10,20,28" ]; then
    abort_suite "[health] ${label}" "loadedTiers (${loaded_tiers:-EMPTY}) != expected."
  elif [ "$all_verified" != "true" ]; then
    abort_suite "[health] ${label}" "nJobsVerified reports at least one tier without n_jobs=1."
  elif [ "$live_tokens" != "$expected_tokens" ]; then
    abort_suite "[health] ${label}" "threadLimiterTokens (${live_tokens:-EMPTY}) != expected (${expected_tokens}) -- override did not take effect."
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
  echo "  [!] transaction-service did not become ready in time." >&2
  return 1
}

check_oom_killed() {
  local label="$1" py_container java_container py_oom java_oom
  py_container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || echo "")
  java_container=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  py_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$py_container" 2>/dev/null || echo "unknown")
  java_oom=$(docker inspect --format '{{.State.OOMKilled}}' "$java_container" 2>/dev/null || echo "unknown")
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

shuffled() { printf '%s\n' "$@" | shuf | tr '\n' ' '; }

capture_run_metadata

echo "[*] Ablation: 3 arms x ${#CELLS[@]} cells / arm-value x ${REPS_ABLATION} reps, target=${ABLATION_TARGET} vus=${ABLATION_VUS}"
for rep in $(seq 1 "$REPS_ABLATION"); do
  echo "[*] --- Ablation repetition ${rep}/${REPS_ABLATION} ---"
  read -ra CELLS_THIS_REP <<< "$(shuffled "${CELLS[@]}")"
  echo "ablation rep=${rep} cell_order=${CELLS_THIS_REP[*]}" >> "$ORDER_LOG"

  for cell in "${CELLS_THIS_REP[@]}"; do
    IFS=':' read -r arm value cpuset cpus workers tokens <<< "$cell"
    label="arm=${arm} value=${value} rep=${rep}"
    echo "  -> ${label}"

    restart_stack "$cpuset" "$cpus" "$workers" "$tokens"
    wait_for_ready
    verify_cpu_pinning "$label"
    verify_tiers_and_limiter "$label" "$tokens"

    echo "  [warm-up] VUS=${ABLATION_VUS}..."
    k6_run warm-up.js WARMUP_TARGETS="$ABLATION_TARGET" WARMUP_VUS="$ABLATION_VUS" -- \
      --out "json=/results/ablation_warmup_${arm}_${value}_rep${rep}.json"
    sleep "$COOLDOWN_S"

    if ! k6_run run-target.js \
      TARGET="$ABLATION_TARGET" VUS="$ABLATION_VUS" ITERATIONS_PER_VU="$ITERATIONS_PER_VU" \
      PHASE=ablation REP="$rep" ARM="$arm" ARM_VALUE="$value" -- \
      --out "json=/results/ablation_${arm}_${value}_rep${rep}.json"
    then
      abort_suite "[cell] ${label}" "k6 exited non-zero."
    fi
    check_oom_killed "$label"
    sleep "$COOLDOWN_S"
  done
done

docker compose -f "$COMPOSE_FILE" down
echo "[+] Ablation complete. Raw results in ${RESULTS_DIR}/ablation_*.json"
echo "    Run: python3 ../analysis/analyze-ablation.py"