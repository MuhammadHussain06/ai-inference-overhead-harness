#!/usr/bin/env bats
# Unit tests for lib/power-state.sh and prepare-host.sh. The readers run against a
# synthetic sysfs tree (POWER_SYSFS_ROOT), so turbo controls, power supplies and power
# limits the running host does not have are testable here; systemctl, powerprofilesctl
# and id are stubbed on PATH.

setup_file() {
  export LT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_DIR="$(cd "${LT_DIR}/.." && pwd)"
}

setup() {
  export POWER_SYSFS_ROOT="${BATS_TEST_TMPDIR}/sys"
  CPU="${POWER_SYSFS_ROOT}/devices/system/cpu"
  PS="${POWER_SYSFS_ROOT}/class/power_supply"
  RAPL="${POWER_SYSFS_ROOT}/class/powercap"
  mkdir -p "$CPU" "$PS" "$RAPL"
  STUB="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB"
  export SYSTEMCTL_LOG="${BATS_TEST_TMPDIR}/systemctl.log"
  export THERMALD_STATE=inactive
  cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
  is-active) echo "$THERMALD_STATE"; [ "$THERMALD_STATE" = active ] ;;
  stop) exit 0 ;;
esac
EOF
  chmod +x "${STUB}/systemctl"
  export PATH="${STUB}:${PATH}"
  # shellcheck source=../lib/host-provenance.sh
  . "${LT_DIR}/lib/host-provenance.sh"
  # shellcheck source=../lib/power-state.sh
  . "${LT_DIR}/lib/power-state.sh"
}

cpus() {
  local c
  for c in $(seq 0 $(($1 - 1))); do
    mkdir -p "${CPU}/cpu${c}/cpufreq"
    echo "${2:-performance}" > "${CPU}/cpu${c}/cpufreq/scaling_governor"
    echo "performance powersave" > "${CPU}/cpu${c}/cpufreq/scaling_available_governors"
    echo performance > "${CPU}/cpu${c}/cpufreq/energy_performance_preference"
  done
}

intel_turbo() { mkdir -p "${CPU}/intel_pstate"; echo "$1" > "${CPU}/intel_pstate/no_turbo"; }

supply() {
  mkdir -p "${PS}/$1"
  echo "$2" > "${PS}/$1/type"
  [ -z "${3:-}" ] || echo "$3" > "${PS}/$1/online"
  [ -z "${4:-}" ] || echo "$4" > "${PS}/$1/status"
}

limits() {
  mkdir -p "${RAPL}/$1"
  echo long_term > "${RAPL}/$1/constraint_0_name"
  echo short_term > "${RAPL}/$1/constraint_1_name"
  echo "$2" > "${RAPL}/$1/constraint_0_power_limit_uw"
  echo "$3" > "${RAPL}/$1/constraint_1_power_limit_uw"
}

prepared_host() { cpus 4; intel_turbo 1; supply ADP1 Mains 1; }

# --- readers ---

@test "turbo: intel_pstate's no_turbo is inverted" {
  intel_turbo 1
  [ "$(turbo_state)" = off ]
  intel_turbo 0
  [ "$(turbo_state)" = on ]
}

@test "turbo: the global cpufreq boost switch, then per-policy boost" {
  mkdir -p "${CPU}/cpufreq"
  echo 1 > "${CPU}/cpufreq/boost"
  [ "$(turbo_state)" = on ]
  rm "${CPU}/cpufreq/boost"
  mkdir -p "${CPU}/cpufreq/policy0" "${CPU}/cpufreq/policy1"
  echo 0 > "${CPU}/cpufreq/policy0/boost"
  echo 0 > "${CPU}/cpufreq/policy1/boost"
  [ "$(turbo_state)" = off ]
  echo 1 > "${CPU}/cpufreq/policy1/boost"
  [ "$(turbo_state)" = mixed ]
}

@test "turbo: a host without a boost control reads unexposed" {
  [ "$(turbo_state)" = unexposed ]
}

@test "governor and energy preference: the distinct values across CPUs, or unexposed" {
  [ "$(governor_state)" = unexposed ]
  cpus 4
  [ "$(governor_state)" = performance ]
  echo powersave > "${CPU}/cpu3/cpufreq/scaling_governor"
  [ "$(governor_state)" = "performance,powersave" ]
  [ "$(energy_preference_state)" = performance ]
}

@test "power source: mains decides, else a discharging battery, else no supply exposed" {
  [ "$(power_source_state)" = no_mains_supply_exposed ]
  supply BAT1 Battery "" Discharging
  [ "$(power_source_state)" = battery ]
  supply ADP1 Mains 1
  [ "$(power_source_state)" = ac ]
  echo 0 > "${PS}/ADP1/online"
  [ "$(power_source_state)" = battery ]
}

@test "power limits: both RAPL interfaces in whole watts, unreadable or unexposed otherwise" {
  [ "$(power_limits_state)" = unexposed ]
  limits intel-rapl:0 200000000 250000000
  limits intel-rapl-mmio:0 30000000 35000000
  [ "$(power_limits_state)" = "msr_pl1=200W,msr_pl2=250W,mmio_pl1=30W,mmio_pl2=35W" ]
  echo "" > "${RAPL}/intel-rapl-mmio:0/constraint_1_power_limit_uw"
  [ "$(power_limits_state)" = "msr_pl1=200W,msr_pl2=250W,mmio_pl1=30W,mmio_pl2=unreadable" ]
}

@test "thermald: running or stopped as systemd reports it" {
  [ "$(thermald_state)" = stopped ]
  THERMALD_STATE=active
  [ "$(thermald_state)" = running ]
}

@test "power profile: unexposed when the daemon does not answer, else its profile" {
  printf '#!/bin/sh\nexit 1\n' > "${STUB}/powerprofilesctl"
  chmod +x "${STUB}/powerprofilesctl"
  [ "$(power_profile_state)" = unexposed ]
  printf '#!/bin/sh\necho performance\n' > "${STUB}/powerprofilesctl"
  chmod +x "${STUB}/powerprofilesctl"
  [ "$(power_profile_state)" = performance ]
}

# --- the required state ---

@test "a prepared host has no problems" {
  prepared_host
  [ -z "$(power_state_problems off)" ]
}

@test "battery, the wrong turbo, a non-performance governor and thermald are each a problem" {
  cpus 2 powersave
  intel_turbo 0
  supply ADP1 Mains 0
  THERMALD_STATE=active
  run power_state_problems off
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "running on battery" ]
  [ "${lines[1]}" = "turbo is on; the run requires off" ]
  [ "${lines[2]}" = "CPU governor is powersave; the run requires performance" ]
  [ "${lines[3]}" = "thermald is running" ]
}

@test "a control the host does not expose is recorded, not a problem" {
  [ -z "$(power_state_problems off)" ]
  [[ "$(power_state_snapshot)" == "power_source=no_mains_supply_exposed turbo=unexposed governor=unexposed "* ]]
}

@test "require_prepared_host: refuses an unprepared host, pointing at prepare-host.sh" {
  prepared_host
  intel_turbo 0
  run require_prepared_host off
  [ "$status" -eq 1 ]
  [[ "$output" == *"turbo is on; the run requires off"* ]]
  [[ "$output" == *"sudo ./prepare-host.sh"* ]]
}

@test "require_prepared_host: records the state a prepared host starts in" {
  prepared_host
  require_prepared_host off > /dev/null
  [ "$POWER_STATE_AT_START" = "$(power_state_snapshot)" ]
  [[ "$POWER_STATE_AT_START" == "power_source=ac turbo=off governor=performance "* ]]
}

@test "check_power_state: passes while unchanged, aborts with both states on any change" {
  prepared_host
  limits intel-rapl-mmio:0 100000000 250000000
  abort_suite() { echo "ABORT $*"; }
  POWER_STATE_AT_START=$(power_state_snapshot)
  [ -z "$(check_power_state "scan rep=1")" ]
  echo 30000000 > "${RAPL}/intel-rapl-mmio:0/constraint_0_power_limit_uw"
  run check_power_state "scan rep=1"
  [[ "$output" == "ABORT [power] scan rep=1 the CPU power state changed during the run"* ]]
  [[ "$output" == *"mmio_pl1=100W"*"mmio_pl1=30W"* ]]
}

@test "power_state_json: valid JSON carrying every snapshot field and the required turbo" {
  prepared_host
  run python3 -c 'import json, sys; m = json.loads(sys.argv[1]); print(m["turbo_required"], m["turbo"], m["power_source"], m["snapshot"] == sys.argv[2])' \
    "$(power_state_json off "$(power_state_snapshot)")" "$(power_state_snapshot)"
  [ "$output" = "off off ac True" ]
}

@test "stop_freq_sampler: a sampler exiting 3 (mains lost) aborts the run, a clean exit does not" {
  # Called directly, not through run: wait only reaps children of the calling shell.
  abort_suite() { echo "ABORT $*"; }
  out="${BATS_TEST_TMPDIR}/out"
  sh -c 'trap "exit 3" TERM; while :; do sleep 0.05; done' &
  FREQ_SAMPLER=$!
  sleep 0.2
  stop_freq_sampler "scan rep=1" > "$out"
  [ "$(cat "$out")" = "ABORT [power] scan rep=1 mains power was lost during the cell." ]
  sh -c 'trap "exit 0" TERM; while :; do sleep 0.05; done' &
  FREQ_SAMPLER=$!
  sleep 0.2
  stop_freq_sampler "scan rep=1" > "$out"
  [ ! -s "$out" ]
}

# --- prepare-host.sh ---

stub_id() { printf '#!/bin/sh\necho %s\n' "$1" > "${STUB}/id"; chmod +x "${STUB}/id"; }

@test "prepare-host.sh: refuses to run without root" {
  stub_id 1000
  run "${REPO_DIR}/prepare-host.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs root"* ]]
}

@test "prepare-host.sh: sets the governor and turbo off, stops thermald, and reports ready" {
  stub_id 0
  cpus 4 powersave
  intel_turbo 0
  supply ADP1 Mains 1
  export THERMALD_STATE=active
  printf '#!/bin/sh\necho "$*" >> "$SYSTEMCTL_LOG"\ncase "$1" in is-active) grep -q "^stop thermald" "$SYSTEMCTL_LOG" && { echo inactive; exit 3; }; echo active ;; esac\n' \
    > "${STUB}/systemctl"
  run "${REPO_DIR}/prepare-host.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "${CPU}/intel_pstate/no_turbo")" = 1 ]
  [ "$(cat "${CPU}/cpu3/cpufreq/scaling_governor")" = performance ]
  grep -q "^stop thermald" "$SYSTEMCTL_LOG"
  [[ "$output" == *"[+] Ready."* ]]
}

@test "prepare-host.sh: TURBO=on through the global boost switch" {
  stub_id 0
  cpus 2
  mkdir -p "${CPU}/cpufreq"
  echo 0 > "${CPU}/cpufreq/boost"
  supply ADP1 Mains 1
  run env TURBO=on "${REPO_DIR}/prepare-host.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "${CPU}/cpufreq/boost")" = 1 ]
  [[ "$output" == *"turbo: on via cpufreq/boost"* ]]
}

@test "prepare-host.sh: still on battery is reported and fails" {
  stub_id 0
  prepared_host
  echo 0 > "${PS}/ADP1/online"
  run "${REPO_DIR}/prepare-host.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"running on battery"* ]]
  [[ "$output" == *"Connect the charger"* ]]
}

@test "prepare-host.sh: rejects a TURBO value other than on or off" {
  run env TURBO=maybe "${REPO_DIR}/prepare-host.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TURBO must be on or off"* ]]
}

# --- the harness scripts read only the live host ---

@test "run-suite.sh, run-ablation.sh and run-openloop.sh refuse a synthetic power tree" {
  for cmd in docker curl shuf; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/${cmd}"
    chmod +x "${STUB}/${cmd}"
  done
  for script in run-suite.sh run-ablation.sh run-openloop.sh; do
    run "${LT_DIR}/${script}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"POWER_SYSFS_ROOT is set to"* ]]
  done
}
