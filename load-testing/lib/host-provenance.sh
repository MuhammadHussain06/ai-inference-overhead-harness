#!/usr/bin/env bash
# Host-state provenance for run_metadata.json: kernel CPU isolation, power source, IRQ
# balancing and virtualization. All four shift measured latency without appearing anywhere
# in the harness's own configuration, so without them two runs look comparable when they
# are not.
#
# Recorded, not enforced here: isolcpus, IRQ balancing and virtualization each have a
# defensible value either way on a given host, so the operator decides. The power source
# is also part of the power state lib/power-state.sh enforces.

# Reports the kernel's live view of isolated CPUs alongside the boot parameter that
# requested them. The two disagree when isolcpus names CPUs that do not exist, so
# both are recorded rather than just the cmdline.
isolcpus_state() {
  local live="" cmdline=""
  if [ -r /sys/devices/system/cpu/isolated ]; then
    live=$(tr -d ' \n' < /sys/devices/system/cpu/isolated 2>/dev/null || echo "")
  else
    live="unreadable"
  fi
  if [ -r /proc/cmdline ]; then
    cmdline=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep '^isolcpus=' | paste -sd' ' - || true)
  fi
  printf '%s|%s' "${live:-none}" "${cmdline:-none}"
}

# Distinguishes mains power from battery. Laptops throttle sustained clocks on battery
# regardless of the governor. A host that exposes no mains supply but a discharging
# battery is on battery; one exposing neither (a desktop or server) reads as
# no_mains_supply_exposed. POWER_SYSFS_ROOT is lib/power-state.sh's test root.
power_source_state() {
  local root="${POWER_SYSFS_ROOT:-/sys}" type_file supply online type
  for type_file in "${root}"/class/power_supply/*/type; do
    [ -r "$type_file" ] || continue
    [ "$(cat "$type_file" 2>/dev/null)" = "Mains" ] || continue
    supply=$(dirname "$type_file")
    online=$(cat "${supply}/online" 2>/dev/null || echo "")
    case "$online" in
      1) printf 'ac' ; return 0 ;;
      0) printf 'battery' ; return 0 ;;
    esac
  done
  for type_file in "${root}"/class/power_supply/*/type; do
    [ -r "$type_file" ] || continue
    type=$(cat "$type_file" 2>/dev/null || echo "")
    supply=$(dirname "$type_file")
    if [ "$type" = "Battery" ] && [ "$(cat "${supply}/status" 2>/dev/null || echo "")" = "Discharging" ]; then
      printf 'battery'
      return 0
    fi
  done
  printf 'no_mains_supply_exposed'
}

# Reports whether interrupts are being migrated across cores during the run. An
# active balancer can move NIC interrupt handling onto a pinned core mid-suite.
irqbalance_state() {
  if command -v systemctl >/dev/null 2>&1; then
    local state
    state=$(systemctl is-active irqbalance 2>/dev/null || true)
    case "$state" in
      active|inactive|failed) printf '%s' "$state" ; return 0 ;;
    esac
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x irqbalance >/dev/null 2>&1; then
    printf 'running_no_systemd_unit'
    return 0
  fi
  printf 'not_present'
}

# Hypervisor or container technology the host runs under, "none" on bare metal. Inside a
# VM the cpusets bind virtual CPUs, whose placement on physical cores the guest cannot
# observe, so pinning is verified only up to the hypervisor.
virtualization_state() {
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v=$(systemd-detect-virt 2>/dev/null || true)
  fi
  printf '%s' "${v:-unknown}"
}

# Emits the four states as a JSON object for embedding in run metadata. Values are
# drawn from a fixed vocabulary or are kernel CPU lists, so none require escaping.
host_provenance_json() {
  local iso live cmdline
  iso=$(isolcpus_state)
  live="${iso%%|*}"
  cmdline="${iso##*|}"
  cat <<EOF
{
    "isolcpus_live": "${live}",
    "isolcpus_cmdline": "${cmdline}",
    "power_source": "$(power_source_state)",
    "irqbalance": "$(irqbalance_state)",
    "virtualization": "$(virtualization_state)"
  }
EOF
}

# One-line console summary, printed next to the existing metadata line.
host_provenance_line() {
  local iso
  iso=$(isolcpus_state)
  printf 'isolcpus=%s power=%s irqbalance=%s virtualization=%s' \
    "${iso%%|*}" "$(power_source_state)" "$(irqbalance_state)" "$(virtualization_state)"
}