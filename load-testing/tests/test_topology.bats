#!/usr/bin/env bats
# Unit tests for lib/topology.sh. A real host only ever exposes one topology; these
# build three synthetic /sys trees so every shape the guard must handle -- adjacent
# SMT pairs, offset-numbered pairs, no SMT, and a hybrid P/E split -- is covered in
# one run instead of only whatever hardware happens to be at hand.

setup_file() {
  export LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/topology.sh"

  # "<root> <n_cpus> <sibling_mode> [hybrid_perf_range]". sibling_mode "adjacent"
  # pairs cpu 2k with 2k+1 (this host's actual scheme, confirmed against its
  # recommend-cpusets.sh output); "offset" pairs cpu i with i+n/2; "none" gives
  # every cpu its own core.
  _build_sys_tree() {
    local root="$1" n="$2" mode="$3" hybrid="${4:-}"
    local base="${root}/devices/system/cpu" c sib
    mkdir -p "$base"
    echo "0-$((n - 1))" > "${base}/online"
    for ((c = 0; c < n; c++)); do
      case "$mode" in
        adjacent) sib="$((c - c % 2)),$((c - c % 2 + 1))" ;;
        offset)   sib="$((c % (n / 2))),$((c % (n / 2) + n / 2))" ;;
        none)     sib="$c" ;;
      esac
      mkdir -p "${base}/cpu${c}/topology"
      echo "$sib" > "${base}/cpu${c}/topology/thread_siblings_list"
    done
    if [ -n "$hybrid" ]; then
      mkdir -p "${root}/devices/cpu_core"
      echo "$hybrid" > "${root}/devices/cpu_core/cpus"
    fi
  }

  # Mirrors the reference host: 8 performance cores as adjacent SMT pairs (cpus
  # 0-15), 16 efficiency cores with no SMT (cpus 16-31).
  export SYS_HYBRID="${BATS_FILE_TMPDIR}/sys-hybrid"
  _build_sys_tree "$SYS_HYBRID" 32 adjacent "0-15"
  # A patched-in E-core range needs its own per-cpu dirs too, since "adjacent"
  # above already wrote pair siblings for all 32; overwrite 16-31 as SMT-less.
  for ((c = 16; c < 32; c++)); do
    echo "$c" > "${SYS_HYBRID}/devices/system/cpu/cpu${c}/topology/thread_siblings_list"
  done

  export SYS_OFFSET="${BATS_FILE_TMPDIR}/sys-offset"
  _build_sys_tree "$SYS_OFFSET" 16 offset

  export SYS_NOSMT="${BATS_FILE_TMPDIR}/sys-nosmt"
  _build_sys_tree "$SYS_NOSMT" 8 none
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
  export TOPO_SYSFS_ROOT="$SYS_HYBRID"
  source "$LIB"
}

# --- pure string helpers, no /sys needed ---

@test "topo_expand_cpuset expands ranges and lists" {
  run topo_expand_cpuset "0-2,5,7-8"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\n1\n2\n5\n7\n8')" ]
}

@test "topo_count_cpus counts and tolerates empty input" {
  [ "$(topo_count_cpus "0-3")" = "4" ]
  [ "$(topo_count_cpus "")" = "0" ]
}

@test "topo_format_cpus collapses contiguous runs" {
  [ "$(topo_format_cpus "0,1,2,4,5,9")" = "0-2,4-5,9" ]
}

# --- topology reads, against the hybrid fixture ---

@test "topo_siblings_of_cpu reads an adjacent SMT pair" {
  [ "$(topo_siblings_of_cpu 2)" = "$(printf '2\n3')" ]
}

@test "topo_core_id is the lowest-numbered sibling" {
  [ "$(topo_core_id 3)" = "2" ]
}

@test "topo_performance_cpus reads the hybrid marker" {
  # topo_performance_cpus yields one cpu per line, already expanded; join with
  # commas before formatting -- topo_format_cpus expects cpuset notation, the
  # same way recommend-cpusets.sh joins cores before calling it.
  [ "$(topo_format_cpus "$(topo_performance_cpus | paste -sd, -)")" = "0-15" ]
}

@test "topo_performance_cpus is empty on a uniform host" {
  TOPO_SYSFS_ROOT="$SYS_NOSMT"
  [ -z "$(topo_performance_cpus)" ]
}

@test "topo_physical_cores restricted to performance cpus finds 8 whole cores" {
  local perf; perf=$(topo_performance_cpus)
  [ "$(topo_physical_cores "$perf" | wc -l)" -eq 8 ]
}

@test "topo_incomplete_cores flags a cpuset owning half a pair" {
  run topo_incomplete_cores "0-1,4-5,8"
  [ "$status" -eq 0 ]
  [[ "$output" == "8:9" ]]
}

@test "topo_incomplete_cores is silent when every pair is whole" {
  run topo_incomplete_cores "0-1,4-5"
  [ -z "$output" ]
}

# --- verify_service_cpuset: the guard the suite actually calls ---

@test "verify_service_cpuset passes on whole, disjoint cores" {
  run verify_service_cpuset "test" "python-service" "0-1,4-5" "4"
  [ "$status" -eq 0 ]
  [[ "$output" == *"owns whole cores"* ]]
}

@test "verify_service_cpuset aborts on an empty cpuset" {
  run verify_service_cpuset "test" "python-service" "" ""
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"resolves no cpuset at all"* ]]
}

@test "verify_service_cpuset aborts when quota exceeds the cpuset" {
  run verify_service_cpuset "test" "python-service" "0-1" "4"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"quota of 4"*"holds only 2"* ]]
}

@test "verify_service_cpuset aborts on a cpu absent from this host" {
  run verify_service_cpuset "test" "python-service" "0-1,99" "3"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"does not expose"* ]]
}

@test "verify_service_cpuset aborts when a cpuset splits a physical core" {
  run verify_service_cpuset "test" "python-service" "2" "1"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"without"*"taking all of it"* ]]
}

# --- the same guard against the other two topologies ---

@test "verify_service_cpuset passes an offset-numbered whole-core pair" {
  TOPO_SYSFS_ROOT="$SYS_OFFSET"
  run verify_service_cpuset "test" "java" "3,11" "2"
  [ "$status" -eq 0 ]
}

@test "verify_service_cpuset rejects a disjoint-by-number pair that is one offset core" {
  # 2 and 10 are siblings on the offset host (2 and 2+8) -- numerically adjacent-
  # looking "2,3" is actually two different physical cores' first threads there.
  TOPO_SYSFS_ROOT="$SYS_OFFSET"
  run verify_service_cpuset "test" "java" "2,3" "2"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ABORT_RECORD")" == *"without"*"taking all of it"* ]]
}

@test "verify_service_cpuset treats every cpu as its own core with no SMT" {
  TOPO_SYSFS_ROOT="$SYS_NOSMT"
  run verify_service_cpuset "test" "k6" "0-1" "2"
  [ "$status" -eq 0 ]
}