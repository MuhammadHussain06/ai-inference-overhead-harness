#!/usr/bin/env bats
# Unit tests for helpers defined in both lib/suite-stack.sh (run-suite.sh, run-openloop.sh)
# and run-ablation.sh. Each function is extracted from the live file text. count_cpuset_cores,
# expand_cpuset and shuffled are run from both files on the same inputs; compose_service_value's
# two copies are compared as text.
#
# core_key_of_cpu, core_keys_of_cpuset, unresolved_cpus_in_cpuset and verify_smt_isolation
# read /sys/devices/system/cpu with no override (unlike lib/topology.sh's TOPO_SYSFS_ROOT),
# so they cannot run against a synthetic topology and are not covered here.

setup_file() {
  export SUITE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-suite.sh"
  export STACK_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/suite-stack.sh"
  export ABLATION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-ablation.sh"

  # Prints one function's source without running the script's top level. Handles the
  # multi-line style (closing brace alone on its line) and one-line definitions
  # ("name() { ...; }"), which need their own exit branch because /^}/ never matches.
  extract_function() {
    awk -v fn="$2" '
      $0 ~ "^" fn "\\(\\) \\{" {
        found = 1
        print
        if ($0 ~ /\}[[:space:]]*$/) exit
        next
      }
      found { print }
      found && /^}/ { exit }
    ' "$1"
  }
  export -f extract_function
}

setup() {
  WORKDIR="$BATS_TEST_TMPDIR"
}

# --- count_cpuset_cores: identical in both files ---

@test "suite-stack.sh count_cpuset_cores sums ranges and singles" {
  extract_function "$STACK_SH" count_cpuset_cores > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  # 0-3 (4) + 7 (1) + 9-10 (2) = 7.
  [ "$(count_cpuset_cores "0-3,7,9-10")" = "7" ]
  [ "$(count_cpuset_cores "")" = "0" ]
}

@test "run-ablation.sh count_cpuset_cores matches suite-stack.sh's" {
  extract_function "$ABLATION_SH" count_cpuset_cores > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  [ "$(count_cpuset_cores "0-3,7,9-10")" = "7" ]
}

# --- expand_cpuset: identical in both files ---

@test "suite-stack.sh expand_cpuset expands ranges and singles in order" {
  extract_function "$STACK_SH" expand_cpuset > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  run expand_cpuset "0-2,5"
  [ "$output" = "$(printf '0\n1\n2\n5')" ]
}

@test "run-ablation.sh expand_cpuset matches suite-stack.sh's" {
  extract_function "$ABLATION_SH" expand_cpuset > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  run expand_cpuset "0-2,5"
  [ "$output" = "$(printf '0\n1\n2\n5')" ]
}

# --- shuffled: a permutation, not a specific order ---

@test "suite-stack.sh shuffled preserves the input multiset" {
  extract_function "$STACK_SH" shuffled > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  result=$(shuffled a b c d)
  read -ra words <<< "$result"
  sorted=$(printf '%s\n' "${words[@]}" | sort | tr '\n' ' ')
  [ "$sorted" = "a b c d " ]
}

@test "run-ablation.sh shuffled preserves the input multiset" {
  extract_function "$ABLATION_SH" shuffled > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  result=$(shuffled a b c d)
  read -ra words <<< "$result"
  sorted=$(printf '%s\n' "${words[@]}" | sort | tr '\n' ' ')
  [ "$sorted" = "a b c d " ]
}

# --- compose_service_value: identical in both files, docker stubbed ---

@test "run-ablation.sh compose_service_value matches suite-stack.sh's" {
  # Both scripts verify their placement through this reader; a divergence would let the
  # ablation verify a different configuration from the one it starts.
  [ "$(extract_function "$STACK_SH" compose_service_value)" \
    = "$(extract_function "$ABLATION_SH" compose_service_value)" ]
}

# --- SCAN_ITERATIONS_PER_VU: the low-VUS reproducibility floor ---

@test "SCAN_ITERATIONS_PER_VU defaults to the same per-VU sample size as baseline" {
  # VUS 1/2/4 fall outside CALIB_AFFECTED_LEVELS and run this flat value; matching
  # BASELINE_ITERATIONS keeps their between-run noise at baseline's level.
  eval "$(grep -m1 '^SCAN_ITERATIONS_PER_VU=' "$SUITE_SH")"
  eval "$(grep -m1 '^BASELINE_ITERATIONS=' "$SUITE_SH")"
  [ "$SCAN_ITERATIONS_PER_VU" = "$BASELINE_ITERATIONS" ]
}

@test "SCAN_ITERATIONS_PER_VU_OVERRIDE still takes precedence over the default" {
  SCAN_ITERATIONS_PER_VU_OVERRIDE=250
  eval "$(grep -m1 '^SCAN_ITERATIONS_PER_VU=' "$SUITE_SH")"
  [ "$SCAN_ITERATIONS_PER_VU" = "250" ]
}

@test "compose_service_value reads a service's cpuset from resolved compose config" {
  extract_function "$STACK_SH" compose_service_value > "${WORKDIR}/f.sh"

  cat > "${WORKDIR}/docker" <<'EOF'
#!/usr/bin/env bash
cat <<'CFG'
services:
  python-service:
    cpuset: "0-1,4-5,8-9"
    cpus: 6.0
  transaction-service:
    cpuset: "2-3,6-7"
    cpus: 4.0
CFG
EOF
  chmod +x "${WORKDIR}/docker"
  export PATH="${WORKDIR}:${PATH}"
  export COMPOSE_FILE="fake-compose.yml"
  source "${WORKDIR}/f.sh"

  [ "$(compose_service_value python-service cpuset)" = "0-1,4-5,8-9" ]
  [ "$(compose_service_value transaction-service cpus)" = "4.0" ]
}

@test "compose_service_value returns empty for a service not in the config" {
  extract_function "$STACK_SH" compose_service_value > "${WORKDIR}/f.sh"
  cat > "${WORKDIR}/docker" <<'EOF'
#!/usr/bin/env bash
cat <<'CFG'
services:
  python-service:
    cpuset: "0-1,4-5,8-9"
CFG
EOF
  chmod +x "${WORKDIR}/docker"
  export PATH="${WORKDIR}:${PATH}"
  export COMPOSE_FILE="fake-compose.yml"
  source "${WORKDIR}/f.sh"

  [ -z "$(compose_service_value k6 cpuset)" ]
}