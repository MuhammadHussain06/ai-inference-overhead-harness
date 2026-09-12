#!/usr/bin/env bash
# CPU topology detection, and the guard that checks a configured cpuset against the
# topology of the host actually running it.
#
# The cpusets in docker-compose.yml are logical CPU numbers, and which physical core a
# number lands on differs by vendor, generation and firmware. verify_smt_isolation()
# establishes that the three services do not share a core with each other; these checks
# establish that each service owns its cores outright, and that the CPU quota beside a
# cpuset is reachable within it. Both hold by construction on the host the values were
# picked for, and neither is guaranteed anywhere else.
#
# Requires the caller to define abort_suite() and CPU_PIN_LOG. TOPO_SYSFS_ROOT points the
# readers at a different tree, which is how the fault-injection suite exercises these
# checks against topologies the running host does not have.
TOPO_SYSFS_ROOT="${TOPO_SYSFS_ROOT:-/sys}"

# Expands a cpuset or sysfs CPU list ("0-2", "0,2,4", "0-1,4-5") to one CPU per line.
topo_expand_cpuset() {
  local part lo hi i
  IFS=',' read -ra _topo_parts <<< "$1"
  for part in "${_topo_parts[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ "$part" == *-* ]]; then
      lo="${part%-*}"; hi="${part#*-}"
      for ((i = lo; i <= hi; i++)); do echo "$i"; done
    elif [ -n "$part" ]; then
      echo "$part"
    fi
  done
}

topo_count_cpus() {
  topo_expand_cpuset "$1" | grep -c . || true
}

# Normalizes a CPU list to ascending order with contiguous runs collapsed to ranges, so a
# generated cpuset reads the same way as a hand-written one.
topo_format_cpus() {
  topo_expand_cpuset "$1" | sort -n -u | awk '
    NR == 1 { lo = hi = $1; next }
    $1 == hi + 1 { hi = $1; next }
    { printf "%s%s", sep, (lo == hi ? lo : lo "-" hi); sep = ","; lo = hi = $1 }
    END { if (NR) printf "%s%s\n", sep, (lo == hi ? lo : lo "-" hi) }
  '
}

# Every logical CPU sharing a physical core with this one, itself included. Empty when
# the host does not expose topology, which is the WSL2 case verify_smt_isolation() warns on.
topo_siblings_of_cpu() {
  local list="${TOPO_SYSFS_ROOT}/devices/system/cpu/cpu${1}/topology/thread_siblings_list"
  [ -r "$list" ] || return 0
  topo_expand_cpuset "$(cat "$list")"
}

# Physical core identity: the lowest-numbered sibling, matching verify_smt_isolation().
topo_core_id() {
  topo_siblings_of_cpu "$1" | sort -n | head -1
}

# Logical CPUs on performance cores, for hosts that expose a hybrid PMU. Empty on
# uniform hosts, where every core is an equally valid choice.
topo_performance_cpus() {
  [ -r "${TOPO_SYSFS_ROOT}/devices/cpu_core/cpus" ] || return 0
  topo_expand_cpuset "$(cat "${TOPO_SYSFS_ROOT}/devices/cpu_core/cpus")"
}

# Prints "<core_id> <cpu,cpu,...>" per physical core, ascending. With an argument,
# considers only CPUs in that list, so a caller can restrict to performance cores.
topo_physical_cores() {
  local restrict="${1:-}" cpu core
  local -A seen=()
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    if [ -n "$restrict" ] && ! grep -qx "$cpu" <<< "$restrict"; then continue; fi
    core=$(topo_core_id "$cpu")
    [ -n "$core" ] || continue
    [ -n "${seen[$core]:-}" ] && continue
    seen[$core]=1
    echo "${core} $(topo_siblings_of_cpu "$cpu" | sort -n | paste -sd, -)"
  done < <(topo_expand_cpuset "$(cat "${TOPO_SYSFS_ROOT}/devices/system/cpu/online" 2>/dev/null || echo "")") \
    | sort -n -k1
}

# Prints "<core_id>:<absent_cpus>" for each physical core the cpuset touches without
# owning every sibling. A half-owned core leaves the other hyperthread schedulable by
# anything else on the host, so the service's cores are shared even though the three
# cpusets are disjoint.
topo_incomplete_cores() {
  local cpuset="$1" cpu core sib missing
  local owned
  owned=$(topo_expand_cpuset "$cpuset" | sort -n -u)
  local -A reported=()
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    core=$(topo_core_id "$cpu")
    [ -n "$core" ] || continue
    [ -n "${reported[$core]:-}" ] && continue
    reported[$core]=1
    missing=""
    while read -r sib; do
      [ -n "$sib" ] || continue
      grep -qx "$sib" <<< "$owned" || missing="${missing}${missing:+,}${sib}"
    done < <(topo_siblings_of_cpu "$cpu")
    [ -n "$missing" ] && echo "${core}:${missing}"
  done <<< "$owned"
  return 0
}

# Aborts unless the service owns whole physical cores and its CPU quota is reachable
# inside its cpuset. A quota above the cpuset size is silently clamped by the kernel,
# so the documented limit and the enforced one diverge without any error.
verify_service_cpuset() {
  local label="$1" service="$2" cpuset="$3" cpus="$4"
  local n_cpus incomplete

  if [ -z "$cpuset" ]; then
    abort_suite "[cpuset] ${label}" "${service} resolves no cpuset at all -- the compose configuration" \
      "was not read, so nothing about this service's core placement is verified."
  fi

  n_cpus=$(topo_count_cpus "$cpuset")
  echo "cpuset_check label=${label} service=${service} cpuset=${cpuset} cpus_in_set=${n_cpus} quota=${cpus:-unset}" \
    >> "$CPU_PIN_LOG"

  if [ -n "$cpus" ] && awk -v q="$cpus" -v n="$n_cpus" 'BEGIN { exit !(q > n) }'; then
    abort_suite "[cpuset] ${label}" "${service} is given a CPU quota of ${cpus} but its cpuset (${cpuset})" \
      "holds only ${n_cpus} logical CPU(s). The kernel enforces the smaller of the two, so the quota" \
      "recorded for this run is not the one applied."
  fi

  if [ ! -r "${TOPO_SYSFS_ROOT}/devices/system/cpu/cpu0/topology/thread_siblings_list" ]; then
    return 0
  fi

  # A CPU with no physical core behind it is absent or offline on this host. It would drop
  # out of the completeness comparison below, which would then pass on the CPUs that remain.
  local absent cpu
  absent=""
  while read -r cpu; do
    [ -n "$cpu" ] || continue
    [ -n "$(topo_core_id "$cpu")" ] || absent="${absent}${absent:+,}${cpu}"
  done < <(topo_expand_cpuset "$cpuset")
  if [ -n "$absent" ]; then
    abort_suite "[cpuset] ${label}" "${service}'s cpuset (${cpuset}) names CPU(s) ${absent}, which this host" \
      "does not expose. The container would run on whatever remains, which is not the placement" \
      "this run records."
  fi

  incomplete=$(topo_incomplete_cores "$cpuset")
  if [ -n "$incomplete" ]; then
    abort_suite "[cpuset] ${label}" "${service}'s cpuset (${cpuset}) takes part of a physical core without" \
      "taking all of it -- core:absent-siblings $(tr '\n' ' ' <<< "$incomplete"). The remaining hyperthread" \
      "stays schedulable by the rest of the host, so this service shares execution units with whatever" \
      "the kernel puts there. Run recommend-cpusets.sh for values that fit this host's topology."
  fi

  echo "  [cpuset] ${label}: ${service} owns whole cores (${cpuset}, ${n_cpus} CPUs, quota ${cpus:-unset})."
}