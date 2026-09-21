#!/usr/bin/env bash
# Standalone probe -- NOT wired into run-suite.sh. Run by hand, stack already up.
#
# common.js records ten telemetry values per successful request: eight
# python_* Trends read off the nested pythonTelemetry object, plus
# java_estimated_bridge_overhead_ms / java_execution_time_ms read off the
# top-level Java response. Every one of these depends on the field actually
# being present in the live response -- a stale container image, a renamed
# field, or a Python-side code path that skips setting one is invisible until
# someone notices a metric missing from analyze-results.py's output, hours
# into a run. This probe hits every strategy directly and checks field
# presence up front, before any of that time is spent.
#
# Note on failure modes: the two java_* fields are read behind an
# `!== undefined` guard in common.js, so a missing one is merely never
# recorded (silent, but harmless). The eight python_* fields are not
# individually guarded -- only the parent `pythonTelemetry` object's presence
# is checked -- so a specific field going missing while the object itself
# still exists passes `undefined` straight into that Trend's .add() call.
# This probe flags that case distinctly ("field missing, object present")
# from the object being absent entirely.
#
# Usage: ./probe_telemetry_completeness.sh [N_REQUESTS] [TARGET...]
# TARGET is one or more of: mock calibration 5 10 20 28 (default: all six).
set -euo pipefail

for _req_cmd in docker curl python3; do
  if ! command -v "$_req_cmd" >/dev/null 2>&1; then
    echo "[!] Required command not found: ${_req_cmd}. Aborting before touching any containers." >&2
    exit 1
  fi
done

N_REQUESTS="${1:-3}"
shift || true
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=(mock calibration 5 10 20 28)
fi
for t in "${TARGETS[@]}"; do
  case "$t" in
    mock|calibration|5|10|20|28) ;;
    *) echo "[!] Unknown target '${t}'. Valid targets: mock calibration 5 10 20 28." >&2; exit 1 ;;
  esac
done

BASE_URL="${BASE_URL:-http://localhost:8080/api/v1/transactions}"

cd "$(dirname "${BASH_SOURCE[0]}")"
COMPOSE_FILE="../../docker-compose.yml"

for svc in python-service transaction-service; do
  cid=$(docker compose -f "$COMPOSE_FILE" ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    echo "[!] Service '${svc}' has no running container under ${COMPOSE_FILE}." >&2
    echo "    Bring the stack up first: docker compose -f docker-compose.yml up -d --wait" >&2
    exit 1
  fi
  state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  if [ "$state" != "running" ]; then
    echo "[!] Service '${svc}' container is '${state}', not running." >&2
    exit 1
  fi
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown")
  if [ "$health" != "none" ] && [ "$health" != "healthy" ]; then
    echo "[!] Service '${svc}' container is running but health is '${health}', not 'healthy'." >&2
    exit 1
  fi
done

# Build freshness is a cheap, direct signal for the most common cause of a
# missing field: the running image predates a source change, silently, since
# neither this probe's preflight nor run-suite.sh's ever rebuilds images --
# `up -d --wait` only starts containers from whatever image already exists.
echo "=== Build freshness ==="
# Scoped to exactly what each Dockerfile COPYs into the image (src/main and
# app/, respectively) -- src/test and fraud-ml-service/tests never reach the
# running container, so a touched test file must not read as a stale image.
for pair in "transaction-service:../../services/transaction-service/src/main" "python-service:../../services/fraud-ml-service/app"; do
  svc="${pair%%:*}"
  src_dir="${pair##*:}"
  cid=$(docker compose -f "$COMPOSE_FILE" ps -q "$svc")
  image_created=$(docker inspect -f '{{.Created}}' "$(docker inspect -f '{{.Image}}' "$cid")" 2>/dev/null || echo "unknown")
  # pipefail disabled inside this subshell only: `sort | head -1` is a classic
  # SIGPIPE trap under pipefail -- once head takes its one line and exits, sort
  # can get killed writing the rest of a large source tree's output, and
  # pipefail then treats that as the whole pipeline failing even though the
  # single line we wanted was already produced correctly.
  newest_src=$(
    set +o pipefail
    find "$src_dir" -type f \( -name '*.java' -o -name '*.py' \) -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-
  )
  newest_mtime="unknown"
  if [ -n "$newest_src" ]; then
    newest_mtime=$(date -r "$newest_src" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown)
  fi
  echo "  ${svc}: image created ${image_created} | newest source ${newest_mtime} ($(basename "${newest_src:-?}"))"
done
git_head=$(git -C ../.. rev-parse HEAD 2>/dev/null || echo "unknown")
git_dirty=$(
  set +o pipefail
  git -C ../.. status --porcelain 2>/dev/null | grep -q . && echo true || echo false
)
echo "  local HEAD: ${git_head}  dirty: ${git_dirty}"
echo "  (if an image predates its newest source file, rebuild before trusting anything below:"
echo "   docker compose -f docker-compose.yml build --no-cache <service> && docker compose -f docker-compose.yml up -d --force-recreate <service>)"
echo

target_strategy() {
  case "$1" in
    mock) echo "DISTRIBUTED_MOCK_GATEWAY" ;;
    calibration) echo "DISTRIBUTED_CALIBRATION_ONLY" ;;
    5|10|20|28) echo "DISTRIBUTED_AI_SYNCHRONOUS" ;;
  esac
}

# One request in, one tab-separated report out: STATUS<TAB>FIELD<TAB>VALUE.
# STATUS is OK, MISSING (key absent) or MISSING_FIELD (key absent but the
# parent pythonTelemetry object is present -- see header note).
check_response() {
  python3 << 'PYEOF'
import json

PY_FIELDS = [
    "parsingRequestTimeMs", "threadDispatchTimeMs", "computationTimeMs",
    "dataframeConstructionTimeMs", "modelInferenceTimeMs", "computeStallMs",
    "serializationResponseTimeMs", "totalPythonExecutionTimeMs",
]
JAVA_FIELDS = ["estimatedBridgeOverheadMs", "executionTimeMs"]

with open("/tmp/probe_telemetry_resp.json") as f:
    obj = json.load(f)

telemetry = obj.get("pythonTelemetry")
rows = []
if telemetry is None:
    for fld in PY_FIELDS:
        rows.append(("MISSING", fld, ""))
else:
    for fld in PY_FIELDS:
        if fld in telemetry and telemetry[fld] is not None:
            rows.append(("OK", fld, telemetry[fld]))
        else:
            rows.append(("MISSING_FIELD", fld, ""))

for fld in JAVA_FIELDS:
    if fld in obj and obj[fld] is not None:
        rows.append(("OK", fld, obj[fld]))
    else:
        rows.append(("MISSING", fld, ""))

for status, fld, val in rows:
    print(f"{status}\t{fld}\t{val}")
PYEOF
}

declare -A FIELD_TOTAL
declare -A FIELD_PRESENT
ANY_HTTP_FAILURE=0

for target in "${TARGETS[@]}"; do
  strategy=$(target_strategy "$target")
  echo "=== Target: ${target} (${strategy}) ==="

  for i in $(seq 1 "$N_REQUESTS"); do
    txid=$(python3 -c "import uuid; print(uuid.uuid4())")
    features_json=$(python3 -c "import random,json; print(json.dumps([random.uniform(-2,2) for _ in range(28)]))")
    if [ "$strategy" = "DISTRIBUTED_AI_SYNCHRONOUS" ]; then
      tier_field=", \"featureTier\": ${target}"
    else
      tier_field=""
    fi
    body="{\"transactionId\": \"${txid}\", \"accountId\": \"ACC-1000\", \"amount\": 100.0, \
\"transactionType\": \"PURCHASE\", \"features\": ${features_json}, \"strategy\": \"${strategy}\"${tier_field}}"

    http_code=$(curl -s -o /tmp/probe_telemetry_resp.json -w '%{http_code}' \
      -X POST "$BASE_URL" -H 'Content-Type: application/json' -d "$body")
    if [ "$http_code" != "200" ]; then
      echo "  [${i}/${N_REQUESTS}] HTTP ${http_code} -- skipping, can't assess a non-200 response." >&2
      cat /tmp/probe_telemetry_resp.json >&2
      ANY_HTTP_FAILURE=1
      continue
    fi

    echo "  [${i}/${N_REQUESTS}] HTTP 200"
    while IFS=$'\t' read -r status fld val; do
      key="${target}|${fld}"
      FIELD_TOTAL["$key"]=$(( ${FIELD_TOTAL["$key"]:-0} + 1 ))
      if [ "$status" = "OK" ]; then
        FIELD_PRESENT["$key"]=$(( ${FIELD_PRESENT["$key"]:-0} + 1 ))
        echo "      ${fld} = ${val}"
      elif [ "$status" = "MISSING_FIELD" ]; then
        echo "      ${fld}: MISSING (pythonTelemetry object present, this key absent)"
      else
        echo "      ${fld}: MISSING"
      fi
    done < <(check_response)
  done
  echo
done

echo "=== Summary ==="
overall_ok=1
for target in "${TARGETS[@]}"; do
  for key in "${!FIELD_TOTAL[@]}"; do
    [[ "$key" == "${target}|"* ]] || continue
    fld="${key#*|}"
    total="${FIELD_TOTAL[$key]}"
    present="${FIELD_PRESENT[$key]:-0}"
    if [ "$present" != "$total" ]; then
      overall_ok=0
      echo "  [!] ${target} / ${fld}: present ${present}/${total}"
    fi
  done
done

if [ "$ANY_HTTP_FAILURE" -eq 1 ]; then
  echo "  [!] At least one request returned a non-200 status -- see stderr above."
  overall_ok=0
fi

if [ "$overall_ok" -eq 1 ]; then
  echo "  [+] Every telemetry field present on every successful request, across all ${#TARGETS[@]} target(s)."
  exit 0
else
  echo
  echo "[!] At least one field is missing somewhere above. Most likely cause is a stale"
  echo "    image -- check the 'Build freshness' section at the top of this output first."
  echo "    Rebuild the affected service, force-recreate, and re-run this probe:"
  echo "      docker compose -f docker-compose.yml build --no-cache <service>"
  echo "      docker compose -f docker-compose.yml up -d --force-recreate <service>"
  exit 1
fi