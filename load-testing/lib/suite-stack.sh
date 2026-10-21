#!/usr/bin/env bash
# Stack restarts, per-rep guards, the warm-up convergence gate and the measured-cell
# wrapper of run-suite.sh, shared with run-openloop.sh so the open-loop check runs under
# the suite's controls.
#
# Requires the caller to define abort_suite(), COMPOSE_FILE, CPU_PIN_LOG, ENV_TRACE_LOG,
# EXPECTED_TIERS, EXPECTED_THREAD_LIMITER_TOKENS, TARGETS, RESULTS_DIR, RAW_RESULTS_DIR,
# KEEP_METRICS, LIB_DIR, PLACEMENT_LOG, SERVICE_CPUSETS and PINNED_CPUS, and to source
# lib/thermal.sh and lib/power-state.sh. verify_smt_isolation() sets SMT_TOPOLOGY_STATUS.

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

# Aborts if two services' cpusets share a physical core through SMT siblings, or if a CPU
# cannot be resolved to a core or a cpuset resolves to none. Records "unverifiable" and
# continues when the host exposes no sibling topology.
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

# The cpuset the kernel actually applied to a container (cgroup v2, else v1); empty if
# unreadable.
read_live_cpuset() {
  local container="$1"
  docker exec "$container" sh -c \
    'cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null' \
    2>/dev/null || echo ""
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

  # "Effective CPU Count" from `-XshowSettings:system` is the value behind
  # Runtime.availableProcessors(), which sizes Netty, ForkJoinPool, G1 and JIT threads.
  # The probe JVM inherits JAVA_TOOL_OPTIONS and so truncates /gc-logs/gc.log, as do
  # verify_jvm_flag_pins()'s probes after it; each rep's archived GC log therefore starts
  # at the last probe, and table_gc_overhead measures it by wall-clock timestamps.
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

  # k6's live cpuset against the resolved compose value, the same source
  # verify_smt_isolation() compared. `docker compose run --rm` can hang on container
  # cleanup, so timeout bounds it (SIGKILL 10 s after SIGTERM).
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

# Aborts unless python-service's /health reports the expected tiers, n_jobs=1 verified for
# each, the expected thread-limiter tokens and single-threaded BLAS/OpenMP; a silent
# tier-load failure would not otherwise show up as a request error.
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

  # Every BLAS/OpenMP thread variable must be exactly 1; the match is comma-delimited
  # because a bare *OMP_NUM_THREADS=1* substring would also accept 10 or 16.
  local tvar
  for tvar in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS NUMEXPR_NUM_THREADS; do
    case ",${thread_env}," in
      *",${tvar}=1,"*) ;;
      *) abort_suite "[tier-check] ${label}" "python-service reports ${tvar} not pinned to exactly 1" \
           "(${thread_env:-EMPTY}) -- numeric libraries may spawn threads outside the measured cpuset." ;;
    esac
  done
}

# Re-checks n_jobs after warm-up, once the tiers have served inference. Each /health call
# is answered by one uvicorn worker, so this polls (up to 10 x workers times) until every
# worker has reported, aborts on any n_jobs != 1, and warns if some worker was never seen.
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
  # From the resolved compose config, not this shell's UVICORN_WORKERS: a value set in .env
  # reaches compose but not this process.
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
# Posts a mock transaction until transaction-service returns 200 (60 tries, 2 s apart);
# `up --wait` only waits for containers with a healthcheck (python-service).
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
  # Through abort_suite, so a readiness timeout reaches the failures log like any other
  # invalidating condition.
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

# Filters a raw k6 file to KEEP_METRICS, gzips it into RESULTS_DIR and deletes the raw copy.
# Runs on the host after the k6 container has exited.
# Usage: finalize_result <name.json>, the name given to --out json=/results/raw/.
finalize_result() {
  local name="$1"
  python3 "${LIB_DIR}/k6_filter.py" finalize "${RAW_RESULTS_DIR}/${name}" "${RESULTS_DIR}/${name}.gz" "$KEEP_METRICS"
  rm -f "${RAW_RESULTS_DIR}/${name}"
}

# Filters a raw k6 chunk to KEEP_METRICS and appends it to a plain file, so
# converge_warmup never accumulates raw chunks.
filter_chunk() {
  python3 "${LIB_DIR}/k6_filter.py" append "$1" "$2" "$KEEP_METRICS"
}

# Gzips an already-filtered file and deletes the plain copy.
gzip_only() {
  python3 "${LIB_DIR}/k6_filter.py" gzip "$1" "$2"
  rm -f "$1"
}

# Warm-up convergence gate. Warm-up runs in WARMUP_CHUNK_DURATION_S chunks until every
# target has converged in the same chunk or MAX_WARMUP_CHUNKS have run; the run then
# proceeds either way and table0 reports each target's verdict. Targets settle at different
# rates, so a fixed budget would waste time on fast ones or short-change slow ones. The
# criterion is lib/warmup_gate.py, which table0 also uses: the median of the last window is
# compared with the window before it and passes within WARMUP_TAIL_TOLERANCE_PCT or
# WARMUP_TAIL_ABS_FLOOR_MS (a percentage alone is unreachably tight for sub-millisecond
# targets). A window is at least WARMUP_WINDOW requests spanning at least
# WARMUP_WINDOW_MIN_S seconds, which covers several GC and scheduler cycles at every
# target's throughput while three windows still fit in one chunk. A target with no HTTP 200
# response never converges. WARMUP_ITERATIONS_PER_TARGET skips the gate for one
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

    # Also checked after the last chunk: that verdict is the state the measured phase
    # starts from.
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

# Aborts if either service container was OOM-killed, or its state is unknown (a container
# that died and was removed also reports unknown).
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

# Renames the JVM's GC log to gc_<label>.log before the next restart_stack starts a JVM
# over it. Called once per rep, after its cells, so the archived log starts at the rep's
# last probe JVM.
archive_gc_log() {
  local label="$1"
  local src="$RESULTS_DIR/gc-logs/gc.log"
  local dest="$RESULTS_DIR/gc-logs/gc_${label}.log"
  if [ -f "$src" ]; then
    mv "$src" "$dest"
  else
    # A warning, not a failure: a missing GC log costs the GC table one row, not the
    # rep's latency data, and any failures-log entry rejects the whole run.
    echo "  [!] No GC log found at ${src} for ${label}; GC overhead is unreported for this rep." >&2
  fi
}

# Samples connection-to-worker placement in the background for one cell, off the
# services' and k6's CPUs. A host where the container's processes are not readable
# gets a placement_unavailable line and the cell runs unaffected.
start_placement_sampler() {
  local cell="$1" container pid
  PLACEMENT_SAMPLER=""
  container=$(docker compose -f "$COMPOSE_FILE" ps -q python-service 2>/dev/null || true)
  pid=$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)
  if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "placement_unavailable cell=${cell} ts=$(thermal_ts) reason=container_pid_unresolved" >> "$PLACEMENT_LOG"
    return 0
  fi
  python3 "${LIB_DIR}/placement.py" --container-pid "$pid" --cell "$cell" \
    --avoid-cpus "$PINNED_CPUS" >> "$PLACEMENT_LOG" 2>/dev/null &
  PLACEMENT_SAMPLER=$!
}

stop_placement_sampler() {
  if [ -n "${PLACEMENT_SAMPLER:-}" ]; then
    kill -TERM "$PLACEMENT_SAMPLER" 2>/dev/null || true
    wait "$PLACEMENT_SAMPLER" 2>/dev/null || true
    PLACEMENT_SAMPLER=""
  fi
}

# Runs one measured cell (named by its result file's stem) between two power checks and
# two thermal samples, under the placement and clock samplers, then checks OOM and the
# thermal guard. A k6 failure aborts the run.
run_cell() {
  local label="$1" cell="$2"
  shift 2
  check_power_state "$label"
  start_placement_sampler "$cell"
  start_freq_sampler "$cell" "$SERVICE_CPUSETS" "$PINNED_CPUS"
  record_cell_thermal start "$cell"
  if ! "$@"; then
    stop_placement_sampler
    stop_freq_sampler "$label"
    abort_suite "[cell] ${label}" "k6 exited non-zero."
  fi
  record_cell_thermal end "$cell"
  stop_freq_sampler "$label"
  stop_placement_sampler
  check_power_state "$label"
  check_oom_killed "$label"
  check_thermal_safety "$label"
}
