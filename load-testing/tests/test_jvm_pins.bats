#!/usr/bin/env bats
# Unit tests for lib/jvm-pins.sh. docker is stubbed so these run without a JVM or a
# Docker daemon: a fake `docker` on PATH answers `compose ... config`, `compose ...
# ps`, and `exec ... sh -c ...` with fixture text, matching the exact shapes
# jvm-pins.sh parses.

setup_file() {
  export LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/jvm-pins.sh"
  export STUB_BIN="${BATS_FILE_TMPDIR}/bin"
  export STUB_DATA="${BATS_FILE_TMPDIR}/data"
  mkdir -p "$STUB_BIN" "$STUB_DATA"

  # Pinned options as docker-compose.yml sets them: everything a real rep expects.
  cat > "${STUB_DATA}/compose_config_pinned.txt" <<'EOF'
services:
  transaction-service:
    environment:
      JAVA_TOOL_OPTIONS: -Xms1536m -Xmx1536m -XX:+UseG1GC -XX:ParallelGCThreads=4 -XX:ConcGCThreads=1 -Dreactor.netty.ioWorkerCount=4 -Xlog:gc*:file=/gc-logs/gc.log
EOF

  # The fault-injection case that broke jvm_option_value: -XX:ParallelGCThreads
  # dropped entirely, everything else intact.
  cat > "${STUB_DATA}/compose_config_missing_flag.txt" <<'EOF'
services:
  transaction-service:
    environment:
      JAVA_TOOL_OPTIONS: -Xms1536m -Xmx1536m -XX:+UseG1GC -XX:ConcGCThreads=1 -Dreactor.netty.ioWorkerCount=4 -Xlog:gc*:file=/gc-logs/gc.log
EOF

  # -XX:+PrintFlagsFinal column layout: type, name, op, value, origin marker(s).
  # This is the fully-pinned baseline -- every flag resolves from JAVA_TOOL_OPTIONS.
  cat > "${STUB_DATA}/printflags_pinned.txt" <<'EOF'
     bool UseG1GC                                  := true                                    {product} {environment}
    uintx ParallelGCThreads                        := 4                                       {product} {environment}
    uintx ConcGCThreads                            := 1                                       {product} {environment}
EOF

  # A collector swap: UseG1GC resolves false, ParallelGCThreads coincidentally
  # matches the pinned value but from ergonomics, not JAVA_TOOL_OPTIONS.
  cat > "${STUB_DATA}/printflags_wrong_collector.txt" <<'EOF'
     bool UseG1GC                                  := false                                   {product} {environment}
    uintx ParallelGCThreads                          = 4                                       {product} {ergonomic}
EOF

  cat > "${STUB_DATA}/proc_comm.txt" <<'EOF'
main
GC Thread#0
GC Thread#1
GC Thread#2
GC Thread#3
G1 Conc#0
reactor-http-ep
reactor-http-ep
reactor-http-ep
reactor-http-ep
EOF

  # Dispatches on the same shape jvm-pins.sh actually invokes: `compose -f <file>
  # config|ps -q transaction-service` and `exec <id> sh -c '<probe>'`. Which
  # fixture "config" or the probe returns is picked by $DOCKER_STUB_MODE, so each
  # test selects a scenario without needing its own copy of this script.
  cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
mode="${DOCKER_STUB_MODE:-pinned}"
if [ "$1" = "compose" ] && [ "$4" = "config" ]; then
  cat "${STUB_DATA}/compose_config_${mode}.txt"
elif [ "$1" = "compose" ] && [ "$4" = "ps" ]; then
  echo "fake_container_id"
elif [ "$1" = "exec" ]; then
  case "$*" in
    *PrintFlagsFinal*) cat "${STUB_DATA}/printflags_${mode}.txt" ;;
    *proc/1/task*) cat "${STUB_DATA}/proc_comm.txt" ;;
  esac
fi
EOF
  chmod +x "${STUB_BIN}/docker"
}

setup() {
  abort_suite() {
    echo "${1}:${*:2}" > "$ABORT_RECORD"
    exit 1
  }
  export -f abort_suite
  ABORT_RECORD="${BATS_TEST_TMPDIR}/abort_record"
  export ABORT_RECORD
  CPU_PIN_LOG="${BATS_TEST_TMPDIR}/cpu_pin_log.txt"
  export CPU_PIN_LOG
  : > "$CPU_PIN_LOG"
  export COMPOSE_FILE="fake-compose.yml"
  export STUB_DATA
  export PATH="${STUB_BIN}:${PATH}"
  export DOCKER_STUB_MODE="pinned"
  source "$LIB"
}

# --- jvm_option_value: the function the fault-injection suite's case 07 broke ---

@test "jvm_option_value reads a present flag" {
  [ "$(jvm_option_value "-XX:ParallelGCThreads" "-XX:+UseG1GC -XX:ParallelGCThreads=4")" = "4" ]
}

@test "jvm_option_value returns empty, not a crash, when the flag is absent" {
  # Reproduces the exact regression: a no-match grep must not take set -e down
  # with it before the caller's own empty-value check runs.
  run bash -c "set -euo pipefail; source '${LIB}'; v=\$(jvm_option_value '-XX:ParallelGCThreads' '-XX:+UseG1GC -XX:ConcGCThreads=1'); echo \"[\${v}]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- jvm_resolved_flag: parses -XX:+PrintFlagsFinal's value and origin columns ---

@test "jvm_resolved_flag reports value and origin for a pinned flag" {
  [ "$(jvm_resolved_flag fake_container_id UseG1GC)" = "true|{product} {environment}" ]
}

@test "jvm_resolved_flag reports an ergonomic origin distinctly" {
  DOCKER_STUB_MODE="wrong_collector"
  [ "$(jvm_resolved_flag fake_container_id ParallelGCThreads)" = "4|{product} {ergonomic}" ]
}

# --- assert_jvm_flag: the per-flag guard ---

@test "assert_jvm_flag passes a matching environment-origin flag" {
  run assert_jvm_flag "test" fake_container_id "UseG1GC" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UseG1GC=true"* ]]
}

@test "assert_jvm_flag aborts on a value mismatch" {
  DOCKER_STUB_MODE="wrong_collector"
  run assert_jvm_flag "test" fake_container_id "ParallelGCThreads" "8"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"resolves ParallelGCThreads=4"*"pins 8"* ]]
}

@test "assert_jvm_flag aborts on a value that only coincidentally matches" {
  DOCKER_STUB_MODE="wrong_collector"
  run assert_jvm_flag "test" fake_container_id "ParallelGCThreads" "4"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"not from the"*"pinned JAVA_TOOL_OPTIONS"* ]]
}

# --- verify_jvm_flag_pins: the fault-injection case 07 scenario end to end ---

@test "verify_jvm_flag_pins passes when every option is pinned" {
  run verify_jvm_flag_pins "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK -- collector and GC worker ceilings resolve"* ]]
}

@test "verify_jvm_flag_pins aborts cleanly, not a raw crash, when a pin is dropped" {
  DOCKER_STUB_MODE="missing_flag"
  run verify_jvm_flag_pins "test"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"does not pin both -XX:ParallelGCThreads"* ]]
}

# --- assert_thread_ceiling ---

@test "assert_thread_ceiling passes at or below the ceiling" {
  run assert_thread_ceiling "test" "gc-worker" 4 4 "-XX:ParallelGCThreads"
  [ "$status" -eq 0 ]
}

@test "assert_thread_ceiling aborts when nothing is alive" {
  run assert_thread_ceiling "test" "gc-worker" 0 4 "-XX:ParallelGCThreads"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"no gc-worker threads are alive"* ]]
}

@test "assert_thread_ceiling aborts above the ceiling" {
  run assert_thread_ceiling "test" "gc-worker" 5 4 "-XX:ParallelGCThreads"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"5 live gc-worker threads exceed the 4 pinned"* ]]
}

# --- verify_jvm_thread_pins: full census against the fixture's proc listing ---

@test "verify_jvm_thread_pins passes when every pool is within its ceiling" {
  run verify_jvm_thread_pins "test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK -- every pinned pool is within its ceiling."* ]]
}