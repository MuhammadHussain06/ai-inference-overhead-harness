#!/usr/bin/env bash
set -euo pipefail

# Orchestrates empirical load tests across clean-slate stack restarts.
#
# Variance & Isolation:
#   - WITHIN-RUN  : Request noise in a single k6 run.
#   - BETWEEN-RUN : Session effects (JIT, GC, OS state) isolated by
#                   restarting docker-compose between reps.
#   - SHUFFLING   : Target/concurrency order randomized per rep to prevent
#                   drift (thermal, GC, memory) from biasing specific cells.
#                   Execution sequence logged to run_order_log.txt.
#
# Suite Strategy:
#   - Repetitions restart stack clean-slate; cells within a rep run sequentially.
#   - Rep Counts: E1 (baseline) = REPS_BASELINE | E2 (concurrency scan) = REPS_SCAN.
#
# Prerequisite: Set APP_DB_SAVE_ENABLED=false in ../docker-compose.yml.

COMPOSE_FILE="../docker-compose.yml"
RESULTS_DIR="../results"
mkdir -p "$RESULTS_DIR"
ORDER_LOG="${RESULTS_DIR}/run_order_log.txt"
: > "$ORDER_LOG"   # truncate/create fresh each suite run

TARGETS=(mock 5 10 20 28)
CONCURRENCY_LEVELS=(1 2 4 8 16 32 64)
BASELINE_ITERATIONS=500
SCAN_ITERATIONS=500
COOLDOWN_S=10
REPS_BASELINE=5
REPS_SCAN=3

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
      -d '{"transactionId":"readiness-check","accountId":"ACC-0","amount":1.0,"transactionType":"PURCHASE","features":[],"strategy":"DISTRIBUTED_MOCK_GATEWAY"}' \
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

echo "[*] E1: baseline decomposition x ${REPS_BASELINE} independent repetitions"
for rep in $(seq 1 "$REPS_BASELINE"); do
  echo "[*] --- Baseline repetition ${rep}/${REPS_BASELINE} ---"
  restart_stack
  wait_for_ready
  echo "[*] Warming up JIT / connection pools..."
  k6 run warm-up.js
  sleep "$COOLDOWN_S"

  # Independent per-rep shuffle of target order.
  read -ra TARGETS_THIS_REP <<< "$(shuffled "${TARGETS[@]}")"
  echo "baseline rep=${rep} target_order=${TARGETS_THIS_REP[*]}" >> "$ORDER_LOG"
  echo "  [order] targets this rep: ${TARGETS_THIS_REP[*]}"

  for target in "${TARGETS_THIS_REP[@]}"; do
    echo "  -> target=${target} rep=${rep}"
    TARGET="$target" VUS=1 ITERATIONS=$BASELINE_ITERATIONS PHASE=baseline REP="$rep" \
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
      TARGET="$target" VUS="$vus" ITERATIONS=$SCAN_ITERATIONS PHASE=scan REP="$rep" \
        k6 run run-target.js \
        --out "json=${RESULTS_DIR}/scan_${target}_vus${vus}_rep${rep}.json"
      sleep "$COOLDOWN_S"
    done
  done
done

echo "[+] Suite complete. Raw results in ${RESULTS_DIR}/"
echo "    Per-rep cell order logged to ${ORDER_LOG}"
echo "    Run: python3 ../analysis/analyze-results.py"
