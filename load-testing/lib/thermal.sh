#!/usr/bin/env bash
# Thermal safety and host telemetry shared by run-suite.sh, run-ablation.sh and the
# warm-up probes. check_thermal_safety() pauses or aborts a run that is overheating;
# the lines written to ENV_TRACE_LOG let the analysis attribute a latency change to
# temperature or thermal throttling per cell instead of inferring it.
#
# Requires the caller to define abort_suite(), ENV_TRACE_LOG and THERMAL_WARN_C /
# THERMAL_CRIT_C / THERMAL_COOLDOWN_S / MAX_THERMAL_COOLDOWNS. THERMAL_MAX_COOLDOWNS_EXTENDED
# is optional and defaults to MAX_THERMAL_COOLDOWNS (no extension) when a caller doesn't set
# it. THERMAL_SYSFS_ROOT points the readers at a synthetic tree for the unit tests.
THERMAL_SYSFS_ROOT="${THERMAL_SYSFS_ROOT:-/sys}"

# UTC with milliseconds: cells short enough to start and end within one second
# still order correctly in the trace.
thermal_ts() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Highest reading across all thermal zones, whole degrees C. Empty when no zone is
# readable; callers then skip the check rather than abort, since this is a safety
# net on the run, not a precondition for it.
read_max_cpu_temp_c() {
  local max="" raw t zone
  for zone in "${THERMAL_SYSFS_ROOT}"/class/thermal/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    raw=$(cat "$zone" 2>/dev/null) || continue
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    t=$((raw / 1000))
    if [ -z "$max" ] || [ "$t" -gt "$max" ]; then
      max="$t"
    fi
  done
  echo "$max"
}

# Cumulative time the kernel has held each core, and CPU 0's package, in thermal
# throttling (Intel therm_throt counters, Linux 5.18 and later), as
# "pkg_throttle_ms=<ms> core_throttle_ms=cpu0=<ms>,cpu1=<ms>,..." in core-index order.
# "na" where the counters are not exposed. The analysis differences them per cell.
read_throttle_ms() {
  local base="${THERMAL_SYSFS_ROOT}/devices/system/cpu" pkg cores
  pkg=$(cat "${base}/cpu0/thermal_throttle/package_throttle_total_time_ms" 2>/dev/null || true)
  cores=$(
    for f in "${base}"/cpu[0-9]*/thermal_throttle/core_throttle_total_time_ms; do
      [ -r "$f" ] || continue
      cpu="${f#"${base}/cpu"}"
      cpu="${cpu%%/*}"
      echo "${cpu} cpu${cpu}=$(cat "$f" 2>/dev/null)"
    done | sort -n -k1,1 | cut -d' ' -f2- | paste -sd, -
  )
  echo "pkg_throttle_ms=${pkg:-na} core_throttle_ms=${cores:-na}"
}

# Samples governor, per-core frequency, temperature and throttle counters at a named
# point in the run, so mid-suite throttling or a governor change is attributable to
# a specific rep rather than inferred from one snapshot taken before it started.
record_env_sample() {
  local governor freqs temp
  governor=$(cat "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
  # Numeric core order, labeled cpuN=khz, so each value attributes to a specific core.
  freqs=$(
    for f in "${THERMAL_SYSFS_ROOT}"/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
      [ -r "$f" ] || continue
      core="${f#"${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu"}"
      core="${core%%/*}"
      echo "${core} cpu${core}=$(cat "$f" 2>/dev/null)"
    done | sort -n -k1,1 | cut -d' ' -f2- | paste -sd, -
  )
  temp=$(read_max_cpu_temp_c)
  echo "env_sample label=${1} ts=$(thermal_ts) governor=${governor} freqs_khz=${freqs:-unavailable}" \
       "temp_c=${temp:-na} $(read_throttle_ms)" >> "$ENV_TRACE_LOG"
}

# Temperature and throttle counters at one edge of a measured cell. Fixed fields
# first and the cell name last, the order the analysis splits them in.
record_cell_thermal() {
  local edge="$1" cell="$2" temp
  temp=$(read_max_cpu_temp_c)
  echo "cell_${edge} ts=$(thermal_ts) temp_c=${temp:-na} $(read_throttle_ms) cell=${cell}" >> "$ENV_TRACE_LOG"
}

# Pauses at/above THERMAL_WARN_C and aborts only if still at/above THERMAL_CRIT_C
# once cooling has stopped making progress: a thermally wedged host loses the whole
# run, one that is still genuinely cooling gets more wall-clock time to keep doing
# so. MAX_THERMAL_COOLDOWNS rounds are always given regardless of trend; beyond
# that, a round is only granted if the previous one actually lowered the reading,
# up to THERMAL_MAX_COOLDOWNS_EXTENDED total -- the moment a round fails to cool,
# further waiting is assumed not to help either, so the check stops there rather
# than spending the rest of the budget. Every check is logged with the time it
# paused for, so the run's thermal pause cost is measured rather than estimated.
check_thermal_safety() {
  local label="$1"
  local ts temp first cooldowns=0 pre
  local hard_cap="${THERMAL_MAX_COOLDOWNS_EXTENDED:-$MAX_THERMAL_COOLDOWNS}"
  ts=$(thermal_ts)
  temp=$(read_max_cpu_temp_c)
  first="$temp"
  while [ -n "$temp" ] && [ "$temp" -ge "$THERMAL_WARN_C" ] && [ "$cooldowns" -lt "$hard_cap" ]; do
    if [ "$cooldowns" -ge "$MAX_THERMAL_COOLDOWNS" ] && [ -n "$pre" ] && [ "$temp" -ge "$pre" ]; then
      break
    fi
    echo "  [thermal] ${label}: ${temp}C >= warn ${THERMAL_WARN_C}C -- cooling ${THERMAL_COOLDOWN_S}s ($((cooldowns + 1))/${hard_cap})"
    pre="$temp"
    sleep "$THERMAL_COOLDOWN_S"
    cooldowns=$((cooldowns + 1))
    temp=$(read_max_cpu_temp_c)
  done
  echo "thermal_check ts=${ts} temp_c=${first:-na} temp_after_c=${temp:-na} cooldowns=${cooldowns}" \
       "paused_s=$((cooldowns * THERMAL_COOLDOWN_S)) label=${label}" >> "$ENV_TRACE_LOG"
  if [ -n "$temp" ] && [ "$temp" -ge "$THERMAL_CRIT_C" ]; then
    abort_suite "[thermal] ${label}" "${temp}C still >= critical ${THERMAL_CRIT_C}C after ${cooldowns} cooldown(s)."
  fi
}
