#!/usr/bin/env bash
# Puts this host in the CPU power state a measurement run requires, then prints it. None
# of these settings survives a reboot, so run it before every run:
#
#   sudo ./prepare-host.sh              # turbo off, what the harness requires by default
#   sudo TURBO=on ./prepare-host.sh     # for runs started with REQUIRED_TURBO_OVERRIDE=on
#
# Sets the performance governor on every CPU, turbo through whichever control the cpufreq
# driver offers, and stops thermald. Controls the host does not expose are reported and
# skipped. Exits non-zero if the host is still not prepared, e.g. on battery.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. load-testing/lib/host-provenance.sh
. load-testing/lib/power-state.sh

TURBO="${TURBO:-off}"
case "$TURBO" in
  on|off) ;;
  *) echo "[!] TURBO must be on or off, got '${TURBO}'." >&2; exit 1 ;;
esac
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Changing the CPU power state needs root: sudo ./prepare-host.sh" >&2
  exit 1
fi

CPU_DIR="${POWER_SYSFS_ROOT}/devices/system/cpu"

set_governor() {
  local f n=0 skipped=0
  for f in "${CPU_DIR}"/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -w "$f" ] || continue
    if grep -qw performance "$(dirname "$f")/scaling_available_governors" 2>/dev/null \
        && echo performance > "$f" 2>/dev/null; then
      n=$((n + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  if [ "$n" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "  governor: cpufreq not exposed on this host, skipped"
  elif [ "$skipped" -eq 0 ]; then
    echo "  governor: performance on ${n} CPU(s)"
  else
    echo "  governor: performance on ${n} CPU(s); ${skipped} CPU(s) offer no performance governor"
  fi
}

# intel_pstate's no_turbo is inverted relative to the boost switches.
set_turbo() {
  local value f paths=()
  if [ -e "${CPU_DIR}/intel_pstate/no_turbo" ]; then
    paths=("${CPU_DIR}/intel_pstate/no_turbo")
    value=$([ "$TURBO" = "on" ] && echo 0 || echo 1)
  else
    if [ -e "${CPU_DIR}/cpufreq/boost" ]; then
      paths=("${CPU_DIR}/cpufreq/boost")
    else
      for f in "${CPU_DIR}"/cpufreq/policy*/boost; do
        [ -e "$f" ] && paths+=("$f")
      done
    fi
    value=$([ "$TURBO" = "on" ] && echo 1 || echo 0)
  fi
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "  turbo: no boost control exposed, skipped"
    return 0
  fi
  for f in "${paths[@]}"; do
    if ! echo "$value" > "$f" 2>/dev/null; then
      echo "  turbo: writing ${f#"${CPU_DIR}/"} was refused; the firmware may fix it"
      return 0
    fi
  done
  echo "  turbo: ${TURBO} via ${paths[0]#"${CPU_DIR}/"}"
}

stop_thermald() {
  if [ "$(thermald_state)" = "running" ]; then
    systemctl stop thermald
    echo "  thermald: stopped (it restarts on the next boot)"
  else
    echo "  thermald: not running"
  fi
}

echo "[*] Preparing the CPU power state (turbo ${TURBO})"
set_governor
set_turbo
stop_thermald

echo "[*] Power state: $(power_state_snapshot)"
problems=$(power_state_problems "$TURBO")
if [ -n "$problems" ]; then
  echo "[!] Still not prepared:" >&2
  sed 's/^/      - /' <<< "$problems" >&2
  [ "$(power_source_state)" = "battery" ] && echo "    Connect the charger and run this again." >&2
  exit 1
fi
echo "[+] Ready. Start the run on this boot; a reboot resets all of the above."
