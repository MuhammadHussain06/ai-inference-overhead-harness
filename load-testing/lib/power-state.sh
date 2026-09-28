#!/usr/bin/env bash
# CPU power state: the settings that decide the clock speed a measured cell runs at.
# Checked when a run starts, which is refused on an unprepared host (prepare-host.sh sets
# it up), and at every rep and cell edge, where any change aborts the run.
#
# Every reader uses the generic Linux interfaces (power_supply, cpufreq, intel_pstate,
# powercap) and reports "unexposed" where a host lacks one, so a desktop, server or VM is
# checked for the controls it has rather than refused for those it lacks.
#
# Requires lib/host-provenance.sh (power_source_state). Callers of check_power_state and
# stop_freq_sampler define abort_suite() and ENV_TRACE_LOG. POWER_SYSFS_ROOT points the
# readers at a synthetic tree for the unit tests.
POWER_SYSFS_ROOT="${POWER_SYSFS_ROOT:-/sys}"

# The distinct values of one per-CPU cpufreq attribute, comma-separated, or "unexposed".
_cpufreq_values() {
  local values
  values=$(cat "${POWER_SYSFS_ROOT}"/devices/system/cpu/cpu[0-9]*/cpufreq/"$1" 2>/dev/null \
    | sort -u | paste -sd, - || true)
  echo "${values:-unexposed}"
}

# "on", "off", "mixed" (policies disagree) or "unexposed", from whichever boost control
# the cpufreq driver offers: intel_pstate's no_turbo, the global boost switch
# (acpi-cpufreq), or per-policy boost (amd-pstate).
turbo_state() {
  local base="${POWER_SYSFS_ROOT}/devices/system/cpu" v=""
  if [ -r "${base}/intel_pstate/no_turbo" ]; then
    v=$(cat "${base}/intel_pstate/no_turbo" 2>/dev/null || true)
    case "$v" in 0) echo on; return ;; 1) echo off; return ;; esac
  fi
  if [ -r "${base}/cpufreq/boost" ]; then
    v=$(cat "${base}/cpufreq/boost" 2>/dev/null || true)
    case "$v" in 1) echo on; return ;; 0) echo off; return ;; esac
  fi
  v=$(cat "${base}"/cpufreq/policy*/boost 2>/dev/null | sort -u | paste -sd, - || true)
  case "$v" in
    1) echo on ;;
    0) echo off ;;
    "") echo unexposed ;;
    *) echo mixed ;;
  esac
}

governor_state() { _cpufreq_values scaling_governor; }

energy_preference_state() { _cpufreq_values energy_performance_preference; }

# The power-profiles-daemon profile, which sets the energy preference and, on some
# firmware, the platform power limits.
power_profile_state() {
  local v=""
  if command -v powerprofilesctl >/dev/null 2>&1; then
    v=$(timeout 5 powerprofilesctl get 2>/dev/null || true)
  fi
  [[ "$v" =~ ^[a-z-]+$ ]] || v="unexposed"
  echo "$v"
}

# thermald adjusts power limits on its own while it runs, so a run requires it stopped.
thermald_state() {
  local v=""
  if command -v systemctl >/dev/null 2>&1; then
    v=$(systemctl is-active thermald 2>/dev/null || true)
  fi
  case "$v" in
    active|activating|reloading) echo running ;;
    inactive|failed|deactivating) echo stopped ;;
    *) if pgrep -x thermald >/dev/null 2>&1; then echo running; else echo stopped; fi ;;
  esac
}

# Sustained (PL1) and short-term (PL2) package power limits in whole watts, from the MSR
# and MMIO RAPL interfaces. The lower of the two applies, and firmware can change either
# with the power source, so both are recorded.
power_limits_state() {
  local base="${POWER_SYSFS_ROOT}/class/powercap" out="" zone label n name key uw
  for zone in intel-rapl:0 intel-rapl-mmio:0; do
    [ -d "${base}/${zone}" ] || continue
    case "$zone" in intel-rapl:0) label=msr ;; *) label=mmio ;; esac
    for n in 0 1; do
      name=$(cat "${base}/${zone}/constraint_${n}_name" 2>/dev/null || true)
      case "$name" in long_term) key=pl1 ;; short_term) key=pl2 ;; *) continue ;; esac
      uw=$(cat "${base}/${zone}/constraint_${n}_power_limit_uw" 2>/dev/null || true)
      if [[ "$uw" =~ ^[0-9]+$ ]]; then uw="$((uw / 1000000))W"; else uw=unreadable; fi
      out+="${out:+,}${label}_${key}=${uw}"
    done
  done
  echo "${out:-unexposed}"
}

# Every field on one line of space-separated key=value pairs; two snapshots are equal
# exactly when the power state is unchanged.
power_state_snapshot() {
  echo "power_source=$(power_source_state) turbo=$(turbo_state) governor=$(governor_state)" \
       "energy_preference=$(energy_preference_state) power_profile=$(power_profile_state)" \
       "thermald=$(thermald_state) power_limits=$(power_limits_state)"
}

# What keeps the current state from being a valid measurement state, one line each;
# empty when the host is prepared. A control the host does not expose is not a problem:
# it is recorded as "unexposed".
power_state_problems() {
  local required_turbo="$1" v
  v=$(power_source_state)
  [ "$v" = "battery" ] && echo "running on battery"
  v=$(turbo_state)
  case "$v" in
    "$required_turbo"|unexposed) ;;
    *) echo "turbo is ${v}; the run requires ${required_turbo}" ;;
  esac
  v=$(governor_state)
  case "$v" in
    performance|unexposed) ;;
    *) echo "CPU governor is ${v}; the run requires performance" ;;
  esac
  [ "$(thermald_state)" = "running" ] && echo "thermald is running"
  return 0
}

# Exits before anything is touched when the host is unprepared; otherwise records the
# state the run starts in as POWER_STATE_AT_START.
require_prepared_host() {
  local required_turbo="$1" problems
  problems=$(power_state_problems "$required_turbo")
  if [ -n "$problems" ]; then
    echo "[!] This host is not in the power state a measurement run requires:" >&2
    sed 's/^/      - /' <<< "$problems" >&2
    echo "    Run 'sudo ./prepare-host.sh' from the repository root, then start again." >&2
    exit 1
  fi
  POWER_STATE_AT_START=$(power_state_snapshot)
  echo "[*] Power state: ${POWER_STATE_AT_START}"
}

check_power_state() {
  local now
  now=$(power_state_snapshot)
  if [ "$now" != "$POWER_STATE_AT_START" ]; then
    abort_suite "[power] $1" "the CPU power state changed during the run (at start: ${POWER_STATE_AT_START};" \
      "now: ${now})."
  fi
}

# The run metadata's power_state object, built from a snapshot so it records exactly the
# state the per-cell checks compare against.
power_state_json() {
  local required_turbo="$1" snapshot="$2" tok
  printf '{\n    "turbo_required": "%s",\n    "snapshot": "%s"' "$required_turbo" "$snapshot"
  for tok in $snapshot; do
    printf ',\n    "%s": "%s"' "${tok%%=*}" "${tok#*=}"
  done
  printf '\n  }'
}

# Samples the services' CPU clock in the background for one cell (lib/cpufreq_sampler.py),
# off the CPUs in avoid_cpus. service_cpusets: "python=<cpuset> java=<cpuset> k6=<cpuset>".
start_freq_sampler() {
  local cell="$1" service_cpusets="$2" avoid_cpus="$3" args=() pair
  for pair in $service_cpusets; do
    args+=(--cpus "$pair")
  done
  python3 "${LIB_DIR}/cpufreq_sampler.py" --cell "$cell" "${args[@]}" --avoid-cpus "$avoid_cpus" \
    >> "$ENV_TRACE_LOG" 2>/dev/null &
  FREQ_SAMPLER=$!
}

# Stops the sampler, which writes the cell's cell_freq line. Its exit status 3 means mains
# power was lost during the cell, which the edge checks alone could miss.
stop_freq_sampler() {
  local rc=0
  [ -n "${FREQ_SAMPLER:-}" ] || return 0
  kill -TERM "$FREQ_SAMPLER" 2>/dev/null || true
  wait "$FREQ_SAMPLER" 2>/dev/null || rc=$?
  FREQ_SAMPLER=""
  if [ "$rc" -eq 3 ]; then
    abort_suite "[power] $1" "mains power was lost during the cell."
  fi
}
