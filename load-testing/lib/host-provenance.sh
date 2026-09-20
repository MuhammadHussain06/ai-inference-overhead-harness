#!/usr/bin/env bash
# Host-state provenance for run_metadata.json: kernel CPU isolation, power source, and
# IRQ balancing. All three shift measured latency without appearing anywhere in the
# harness's own configuration, so without them two runs look comparable when they are not.
#
# Recorded, never enforced: each setting has a defensible value either way on a given
# host, so the operator decides. Only conditions that invalidate a measurement outright
# abort a run.

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
# regardless of the governor, and the env trace's governor/frequency samples alone
# attribute the resulting mid-suite drift to the wrong cause.
power_source_state() {
  local type_file supply online
  for type_file in /sys/class/power_supply/*/type; do
    [ -r "$type_file" ] || continue
    [ "$(cat "$type_file" 2>/dev/null)" = "Mains" ] || continue
    supply=$(dirname "$type_file")
    online=$(cat "${supply}/online" 2>/dev/null || echo "")
    case "$online" in
      1) printf 'ac' ; return 0 ;;
      0) printf 'battery' ; return 0 ;;
    esac
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

# Emits the three states as a JSON object for embedding in run metadata. Values are
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
    "irqbalance": "$(irqbalance_state)"
  }
EOF
}

# One-line console summary, printed next to the existing metadata line.
host_provenance_line() {
  local iso
  iso=$(isolcpus_state)
  printf 'isolcpus=%s power=%s irqbalance=%s' \
    "${iso%%|*}" "$(power_source_state)" "$(irqbalance_state)"
}