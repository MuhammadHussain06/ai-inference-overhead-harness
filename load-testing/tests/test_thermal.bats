#!/usr/bin/env bats
# Unit tests for lib/thermal.sh: the thermal safety check both harness scripts run
# after every cell and warm-up chunk, and the telemetry lines table8 and the ablation
# thermal tables are built from. The readers run against a synthetic sysfs tree
# (THERMAL_SYSFS_ROOT), so temperatures and throttle counters the running host does
# not have are testable here.

setup_file() {
  export LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/thermal.sh"
  export SUITE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

setup() {
  export THERMAL_SYSFS_ROOT="${BATS_TEST_TMPDIR}/sys"
  mkdir -p "${THERMAL_SYSFS_ROOT}/class/thermal" "${THERMAL_SYSFS_ROOT}/devices/system/cpu"
  export ENV_TRACE_LOG="${BATS_TEST_TMPDIR}/env_trace.txt"
  : > "$ENV_TRACE_LOG"
  export ABORT_RECORD="${BATS_TEST_TMPDIR}/abort"
  THERMAL_WARN_C=90
  THERMAL_CRIT_C=95
  THERMAL_COOLDOWN_S=60
  MAX_THERMAL_COOLDOWNS=2
  abort_suite() { echo "$*" > "$ABORT_RECORD"; exit 1; }
  # Records each pause instead of taking it; a test that cools the host during a
  # pause lowers the zone reading from here.
  sleep() { echo "slept $1" >> "${BATS_TEST_TMPDIR}/sleeps"; [ -n "${COOL_TO:-}" ] && zone 0 "$COOL_TO"; return 0; }
  source "$LIB"
}

# zone <n> <millidegrees>
zone() {
  mkdir -p "${THERMAL_SYSFS_ROOT}/class/thermal/thermal_zone$1"
  echo "$2" > "${THERMAL_SYSFS_ROOT}/class/thermal/thermal_zone$1/temp"
}

# core_throttle <cpu> <ms>
core_throttle() {
  mkdir -p "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu$1/thermal_throttle"
  echo "$2" > "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu$1/thermal_throttle/core_throttle_total_time_ms"
}

# --- readers ---

@test "the temperature is the hottest readable zone, in whole degrees" {
  zone 0 45000
  zone 1 87999
  zone 2 "not-a-number"
  [ "$(read_max_cpu_temp_c)" = "87" ]
}

@test "no readable zone reads as empty, not zero" {
  [ -z "$(read_max_cpu_temp_c)" ]
}

@test "throttle counters are listed per CPU in numeric order with the package counter" {
  core_throttle 10 7
  core_throttle 2 5
  core_throttle 0 3
  echo 11 > "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms"
  [ "$(read_throttle_ms)" = "pkg_throttle_ms=11 core_throttle_ms=cpu0=3,cpu2=5,cpu10=7" ]
}

@test "a host without throttle counters reports na rather than zero" {
  [ "$(read_throttle_ms)" = "pkg_throttle_ms=na core_throttle_ms=na" ]
}

# --- the trace lines ---

@test "a cell edge records temperature and counters, with the cell name last" {
  zone 0 71000
  core_throttle 0 3
  record_cell_thermal start "scan_28_vus64_rep1"
  line=$(cat "$ENV_TRACE_LOG")
  [[ "$line" =~ ^cell_start\ ts=[0-9T:.-]+Z\ temp_c=71\ pkg_throttle_ms=na\ core_throttle_ms=cpu0=3\ cell=scan_28_vus64_rep1$ ]]
}

@test "an env sample records its label, governor, frequencies, temperature and counters" {
  zone 0 60000
  mkdir -p "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu0/cpufreq"
  echo performance > "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  echo 3000000 > "${THERMAL_SYSFS_ROOT}/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
  record_env_sample "scan_rep1_start"
  line=$(cat "$ENV_TRACE_LOG")
  [[ "$line" == "env_sample label=scan_rep1_start ts="* ]]
  [[ "$line" == *" governor=performance freqs_khz=cpu0=3000000 temp_c=60 pkg_throttle_ms=na core_throttle_ms=na" ]]
}

# --- the safety check ---

@test "a host below the warning threshold is logged without pausing" {
  zone 0 70000
  run check_thermal_safety "scan target=28 vus=64 rep=1"
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/sleeps" ]
  [[ "$(cat "$ENV_TRACE_LOG")" == "thermal_check ts="*" temp_c=70 temp_after_c=70 cooldowns=0 paused_s=0 label=scan target=28 vus=64 rep=1" ]]
}

@test "a hot host pauses, and the pause it took is logged" {
  zone 0 91000
  COOL_TO=80000
  run check_thermal_safety "baseline target=28 rep=1"
  [ "$status" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/sleeps")" = "slept 60" ]
  [[ "$(cat "$ENV_TRACE_LOG")" == *" temp_c=91 temp_after_c=80 cooldowns=1 paused_s=60 label=baseline target=28 rep=1" ]]
}

@test "a host still critical after every cooldown aborts the run" {
  zone 0 96000
  run check_thermal_safety "warmup_scan_rep1 chunk2"
  [ "$status" -eq 1 ]
  [ "$(grep -c . "${BATS_TEST_TMPDIR}/sleeps")" = "2" ]
  [[ "$(cat "$ABORT_RECORD")" == "[thermal] warmup_scan_rep1 chunk2 96C still >= critical 95C after 2 cooldown(s)." ]]
  [[ "$(cat "$ENV_TRACE_LOG")" == *" cooldowns=2 paused_s=120 label=warmup_scan_rep1 chunk2" ]]
}

@test "a host between warning and critical after its cooldowns continues" {
  zone 0 92000
  run check_thermal_safety "scan target=5 vus=8 rep=2"
  [ "$status" -eq 0 ]
  [ "$(grep -c . "${BATS_TEST_TMPDIR}/sleeps")" = "2" ]
}

@test "an unreadable temperature is logged as na and never aborts" {
  run check_thermal_safety "baseline target=mock rep=1"
  [ "$status" -eq 0 ]
  [[ "$(cat "$ENV_TRACE_LOG")" == *" temp_c=na temp_after_c=na cooldowns=0 paused_s=0 label=baseline target=mock rep=1" ]]
}

# --- the harness refuses a synthetic tree ---

@test "run-suite.sh and run-ablation.sh refuse to run against a synthetic sysfs tree" {
  stub="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub"
  for cmd in docker curl shuf; do
    printf '#!/bin/sh\nexit 0\n' > "${stub}/${cmd}"
    chmod +x "${stub}/${cmd}"
  done
  for script in run-suite.sh run-ablation.sh; do
    run env PATH="${stub}:${PATH}" THERMAL_SYSFS_ROOT="$THERMAL_SYSFS_ROOT" "${SUITE_DIR}/${script}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"THERMAL_SYSFS_ROOT is set to"* ]]
  done
}
