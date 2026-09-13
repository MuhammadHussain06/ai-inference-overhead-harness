#!/usr/bin/env bash
# Verifies the JVM thread pins the measurement depends on: G1 as the collector, its
# worker-thread ceilings, and Reactor Netty's event-loop count. verify_cpu_pinning()
# already confirms the JVM detects the right core count; these checks confirm the
# thread pools sized off it are the pinned values rather than ergonomic ones.
#
# Requires the caller to define abort_suite() and CPU_PIN_LOG.
#
# Split in two because the flag probe starts a second JVM in the container, which
# opens -- and so truncates -- the shared /gc-logs/gc.log. Flag checks therefore run
# at rep start, alongside verify_cpu_pinning(), which already pays that cost; the
# thread census reads /proc only and runs after warm-up, once every event loop has
# served traffic.

# Resolves the transaction-service container, so call sites stay one-liners like the
# harness's other per-rep guards.
jvm_container() {
  local id
  id=$(docker compose -f "$COMPOSE_FILE" ps -q transaction-service 2>/dev/null || echo "")
  if [ -z "$id" ]; then
    abort_suite "[jvm-pin] ${1}" "could not resolve the transaction-service container -- the JVM's" \
      "pinned collector and thread pools are unverifiable for this rep."
  fi
  printf '%s' "$id"
}

# Extracts the JVM options the compose file pins, so expectations track the compose
# file rather than a second copy of the same numbers maintained by hand.
jvm_pinned_options() {
  docker compose -f "$COMPOSE_FILE" config 2>/dev/null \
    | sed -n 's/^ *JAVA_TOOL_OPTIONS: *//p' | head -1
}

# Reads a numeric -XX: or -D option out of an options string.
jvm_option_value() {
  printf '%s\n' "$2" | grep -o -- "${1}=[0-9]\+" | head -1 | sed 's/.*=//'  || true
}

# Reports "<value>|<origin>" for a flag as the JVM itself resolves it. The origin
# distinguishes a pinned value from an ergonomic one that happens to coincide on
# this host, which a value comparison alone cannot.
jvm_resolved_flag() {
  docker exec "$1" sh -c 'java -XX:+PrintFlagsFinal -version 2>/dev/null' 2>/dev/null \
    | awk -v flag="$2" '$2 == flag {
        origin = ""
        for (i = 5; i <= NF; i++) origin = origin (origin ? " " : "") $i
        print $4 "|" origin
        exit
      }'
}

# Aborts unless the JVM resolves the flag to the expected value from an explicit
# source. An {ergonomic} or {default} origin means JAVA_TOOL_OPTIONS never reached
# this JVM and the value was derived from whatever cores the host happens to expose.
assert_jvm_flag() {
  local label="$1" container="$2" flag="$3" expected="$4"
  local resolved value origin
  resolved=$(jvm_resolved_flag "$container" "$flag")
  value="${resolved%%|*}"
  origin="${resolved##*|}"

  echo "  [jvm-pin] ${label}: ${flag}=${value:-EMPTY} origin(${origin:-EMPTY}) expected(${expected})"
  echo "jvm_pin_check label=${label} flag=${flag} value=${value:-EMPTY} origin=${origin:-EMPTY} expected=${expected}" \
    >> "$CPU_PIN_LOG"

  if [ -z "$value" ]; then
    abort_suite "[jvm-pin] ${label}" "could not read ${flag} from the JVM's own resolved flags --" \
      "the thread pool it sizes is unverifiable for this rep."
  elif [ "$value" != "$expected" ]; then
    abort_suite "[jvm-pin] ${label}" "the JVM resolves ${flag}=${value}, but docker-compose.yml pins" \
      "${expected}. The pool sized by this flag is not the one the run is documented to use."
  fi
  case "$origin" in
    *ergonomic*|*default*)
      abort_suite "[jvm-pin] ${label}" "the JVM resolves ${flag}=${value} from ${origin}, not from the" \
        "pinned JAVA_TOOL_OPTIONS. The value matches by coincidence on this host and would be sized" \
        "off core count on any host with a different cpuset." ;;
  esac
}

# Confirms the pinned JVM options reach the JVM and resolve to the pinned values.
# Starts a probe JVM -- call only at rep start, before measured traffic.
verify_jvm_flag_pins() {
  local label="$1"
  local container opts gc_threads conc_threads
  container=$(jvm_container "$label")

  opts=$(jvm_pinned_options)
  if [ -z "$opts" ]; then
    abort_suite "[jvm-pin] ${label}" "docker-compose.yml resolves no JAVA_TOOL_OPTIONS for" \
      "transaction-service -- collector and thread-pool pinning is absent, not merely unverified."
  fi

  case "$opts" in
    *-XX:+UseG1GC*) ;;
    *) abort_suite "[jvm-pin] ${label}" "JAVA_TOOL_OPTIONS no longer pins -XX:+UseG1GC" \
         "(${opts}) -- GC pause data would not be comparable across reps or hosts." ;;
  esac

  gc_threads=$(jvm_option_value "-XX:ParallelGCThreads" "$opts")
  conc_threads=$(jvm_option_value "-XX:ConcGCThreads" "$opts")
  if [ -z "$gc_threads" ] || [ -z "$conc_threads" ]; then
    abort_suite "[jvm-pin] ${label}" "JAVA_TOOL_OPTIONS does not pin both -XX:ParallelGCThreads and" \
      "-XX:ConcGCThreads (${opts}) -- GC worker counts would follow JVM ergonomics per host."
  fi

  assert_jvm_flag "$label" "$container" "UseG1GC" "true"
  assert_jvm_flag "$label" "$container" "ParallelGCThreads" "$gc_threads"
  assert_jvm_flag "$label" "$container" "ConcGCThreads" "$conc_threads"

  echo "  [jvm-pin] ${label}: OK -- collector and GC worker ceilings resolve from the pinned options."
}

# Counts live threads whose name starts with the given prefix in the container's PID 1.
count_jvm_threads() {
  docker exec "$1" sh -c 'cat /proc/1/task/*/comm 2>/dev/null' 2>/dev/null \
    | grep -c "^$2" || true
}

# Aborts if a live pool exceeds its pinned ceiling, or is empty when traffic has
# already run. Counts are ceilings rather than exact matches: UseDynamicNumberOfGCThreads
# creates GC workers on demand up to ParallelGCThreads, and Netty starts an event loop's
# thread on that loop's first task, so a count below the ceiling means the pool was never
# driven that hard, while a count above it means the ceiling was never applied.
assert_thread_ceiling() {
  local label="$1" pool="$2" observed="$3" ceiling="$4" source_flag="$5"

  echo "  [jvm-threads] ${label}: ${pool} live(${observed}) ceiling(${ceiling} from ${source_flag})"
  echo "jvm_thread_check label=${label} pool=${pool} live=${observed} ceiling=${ceiling}" >> "$CPU_PIN_LOG"

  if [ "$observed" -eq 0 ]; then
    abort_suite "[jvm-threads] ${label}" "no ${pool} threads are alive in the JVM after warm-up --" \
      "either the process is not the one under test or the pool never started, and neither leaves" \
      "the pinned ${source_flag} verifiable."
  elif [ "$observed" -gt "$ceiling" ]; then
    abort_suite "[jvm-threads] ${label}" "${observed} live ${pool} threads exceed the ${ceiling} pinned" \
      "by ${source_flag} -- the pin did not bound the pool, so this rep runs more parallelism than the" \
      "cpuset and the documented configuration allow."
  fi
}

# Censuses the JVM's live thread pools against their pinned ceilings. Reads /proc
# only -- safe to call after measured traffic has begun.
verify_jvm_thread_pins() {
  local label="$1"
  local container opts gc_threads conc_threads io_workers
  local gc_live conc_live io_live
  container=$(jvm_container "$label")

  opts=$(jvm_pinned_options)
  gc_threads=$(jvm_option_value "-XX:ParallelGCThreads" "$opts")
  conc_threads=$(jvm_option_value "-XX:ConcGCThreads" "$opts")
  io_workers=$(jvm_option_value "-Dreactor.netty.ioWorkerCount" "$opts")
  if [ -z "$gc_threads" ] || [ -z "$conc_threads" ] || [ -z "$io_workers" ]; then
    abort_suite "[jvm-threads] ${label}" "JAVA_TOOL_OPTIONS does not pin all of -XX:ParallelGCThreads," \
      "-XX:ConcGCThreads and -Dreactor.netty.ioWorkerCount (${opts:-EMPTY}) -- live thread pools have" \
      "no documented ceiling to check against."
  fi

  gc_live=$(count_jvm_threads "$container" "GC Thread#")
  conc_live=$(count_jvm_threads "$container" "G1 Conc#")
  # /proc truncates thread names at 15 characters, so every reactor-http-epoll-N
  # loop reads as this one prefix; the count is what identifies them.
  io_live=$(count_jvm_threads "$container" "reactor-http-ep")

  assert_thread_ceiling "$label" "gc-worker" "$gc_live" "$gc_threads" "-XX:ParallelGCThreads"
  assert_thread_ceiling "$label" "gc-concurrent" "$conc_live" "$conc_threads" "-XX:ConcGCThreads"
  assert_thread_ceiling "$label" "netty-event-loop" "$io_live" "$io_workers" "-Dreactor.netty.ioWorkerCount"

  echo "  [jvm-threads] ${label}: OK -- every pinned pool is within its ceiling."
}