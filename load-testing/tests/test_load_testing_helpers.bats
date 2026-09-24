#!/usr/bin/env bats
# Unit tests for the pure-logic helpers embedded directly in run-suite.sh and
# run-ablation.sh (not library files, so each function is extracted from the real
# script text rather than copy-pasted here -- these tests run the actual current
# implementation, and would catch the two scripts' duplicated copies drifting
# apart from each other).
#
# count_cpuset_cores, expand_cpuset and shuffled touch no filesystem or Docker
# state, so they are testable as-is. core_key_of_cpu, core_keys_of_cpuset,
# unresolved_cpus_in_cpuset and verify_smt_isolation all read
# /sys/devices/system/cpu directly with no override (unlike lib/topology.sh's
# TOPO_SYSFS_ROOT), so they cannot be pointed at a synthetic topology without
# first adding that same override to them; they are left uncovered here rather
# than tested only against whatever real host happens to run this suite.

setup_file() {
  export SUITE_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-suite.sh"
  export ABLATION_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/run-ablation.sh"

  # Pulls one function's current source out of a script without executing the
  # script's own top-level side effects (arg parsing, preflight checks, ...).
  # Handles both this codebase's multi-line style (closing brace alone on its
  # line) and a one-line definition ("name() { ...; }" all on the line that
  # opens it) -- the latter needs its own immediate-exit branch, since the
  # multi-line exit check (/^}/) never matches a line that starts with the
  # function's name instead of "}".
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

# --- count_cpuset_cores: identical in both scripts ---

@test "run-suite.sh count_cpuset_cores sums ranges and singles" {
  extract_function "$SUITE_SH" count_cpuset_cores > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  # 0-3 (4) + 7 (1) + 9-10 (2) = 7.
  [ "$(count_cpuset_cores "0-3,7,9-10")" = "7" ]
  [ "$(count_cpuset_cores "")" = "0" ]
}

@test "run-ablation.sh count_cpuset_cores matches run-suite.sh's" {
  extract_function "$ABLATION_SH" count_cpuset_cores > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  [ "$(count_cpuset_cores "0-3,7,9-10")" = "7" ]
}

# --- expand_cpuset: identical in both scripts ---

@test "run-suite.sh expand_cpuset expands ranges and singles in order" {
  extract_function "$SUITE_SH" expand_cpuset > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  run expand_cpuset "0-2,5"
  [ "$output" = "$(printf '0\n1\n2\n5')" ]
}

@test "run-ablation.sh expand_cpuset matches run-suite.sh's" {
  extract_function "$ABLATION_SH" expand_cpuset > "${WORKDIR}/f.sh"
  source "${WORKDIR}/f.sh"
  run expand_cpuset "0-2,5"
  [ "$output" = "$(printf '0\n1\n2\n5')" ]
}

# --- shuffled: a permutation, not a specific order ---

@test "run-suite.sh shuffled preserves the input multiset" {
  extract_function "$SUITE_SH" shuffled > "${WORKDIR}/f.sh"
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

# --- compose_service_value: identical in both scripts, docker stubbed ---

@test "run-ablation.sh compose_service_value matches run-suite.sh's" {
  # Both scripts check their placement against this reader, so a divergence would
  # let the ablation verify a different configuration from the one it starts.
  [ "$(extract_function "$SUITE_SH" compose_service_value)" \
    = "$(extract_function "$ABLATION_SH" compose_service_value)" ]
}

# --- SCAN_ITERATIONS_PER_VU: the low-VUS reproducibility floor ---

@test "SCAN_ITERATIONS_PER_VU defaults to the same per-VU sample size as baseline" {
  # VUS 1/2/4 fall outside CALIB_AFFECTED_LEVELS and get this flat value directly; a
  # regression back to a much smaller default would reopen the high between-run CoV
  # those levels showed before this was raised to match BASELINE_ITERATIONS.
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
  extract_function "$SUITE_SH" compose_service_value > "${WORKDIR}/f.sh"

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
  extract_function "$SUITE_SH" compose_service_value > "${WORKDIR}/f.sh"
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