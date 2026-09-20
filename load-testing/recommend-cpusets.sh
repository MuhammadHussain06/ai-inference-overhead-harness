#!/usr/bin/env bash
set -euo pipefail

# Prints cpuset values that fit this host's CPU topology, as environment assignments the
# suite and the ablation read.
#
# The values checked into docker-compose.yml are logical CPU numbers chosen for one
# machine. Which physical core a number lands on is vendor- and generation-specific, so on
# another host the same numbers can take one hyperthread of each of two cores instead of
# both threads of one -- disjoint cpusets over shared hardware. This prints numbers that
# hold on the host it runs on; verify_service_cpuset() rejects the run if they do not.
#
# Recommends only. Review the output, then export it before running the suite.

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck disable=SC2034  # read by the sourced topology helpers
CPU_PIN_LOG=/dev/null
abort_suite() { echo "[!] ${*}" >&2; exit 1; }
. lib/topology.sh

# Physical cores reserved per service. python-service takes four because the ablation's
# cpuset arm sweeps one, three and four cores against the same reservation; the suite
# itself uses the three-core control value.
PYTHON_CORES=4
PYTHON_CONTROL_CORES=3
JAVA_CORES=2
K6_CORES=2
REQUIRED=$((PYTHON_CORES + JAVA_CORES + K6_CORES))

if [ ! -r "${TOPO_SYSFS_ROOT}/devices/system/cpu/cpu0/topology/thread_siblings_list" ]; then
  echo "[!] This host does not expose CPU topology (common under WSL2), so physical-core" >&2
  echo "    placement cannot be derived. Run the suite on a host that does, or accept that" >&2
  echo "    physical-core isolation stays unverified for the run." >&2
  exit 1
fi

# Performance cores only, where the host has two kinds. Mixing them would put services on
# cores with different clocks and cache, which is a difference between services rather
# than between the conditions under test.
PERF_CPUS=$(topo_performance_cpus)
HYBRID="no"
if [ -n "$PERF_CPUS" ]; then HYBRID="yes"; fi

mapfile -t CORES < <(topo_physical_cores "$PERF_CPUS")
TOTAL=${#CORES[@]}

echo "# Host topology"
echo "#   physical cores available for pinning: ${TOTAL}$([ "$HYBRID" = yes ] && echo " (performance cores only; this host is hybrid)")"
echo "#   required by the harness: ${REQUIRED} (python ${PYTHON_CORES}, java ${JAVA_CORES}, k6 ${K6_CORES})"

if [ "$TOTAL" -lt "$REQUIRED" ]; then
  echo "" >&2
  echo "[!] This host has ${TOTAL} usable physical core(s); the harness pins ${REQUIRED}." >&2
  echo "    Running it here would either overlap services or leave the host no cores of its" >&2
  echo "    own, and neither produces numbers comparable to a host that fits." >&2
  exit 1
fi

# Contiguous blocks in ascending order: any assignment of whole, disjoint cores is
# equivalent for isolation, and contiguous blocks are the ones a reader can check by eye.
cpus_of_cores() {
  local start="$1" count="$2" i out=""
  for ((i = start; i < start + count; i++)); do
    out="${out}${out:+,}${CORES[i]#* }"
  done
  topo_format_cpus "$out"
}

PY_WIDE=$(cpus_of_cores 0 "$PYTHON_CORES")
PY_CONTROL=$(cpus_of_cores 0 "$PYTHON_CONTROL_CORES")
PY_NARROW=$(cpus_of_cores 0 1)
JAVA=$(cpus_of_cores "$PYTHON_CORES" "$JAVA_CORES")
K6=$(cpus_of_cores $((PYTHON_CORES + JAVA_CORES)) "$K6_CORES")

# Each quota matches the cpuset it accompanies; a larger one is clamped by the kernel and
# would misreport the limit actually applied.
echo ""
echo "export PYTHON_CPUSET=\"${PY_CONTROL}\""
echo "export PYTHON_CPUS=\"$(topo_count_cpus "$PY_CONTROL").0\""
echo "export JAVA_CPUSET=\"${JAVA}\""
echo "export JAVA_CPUS=\"$(topo_count_cpus "$JAVA").0\""
echo "export K6_CPUSET=\"${K6}\""
echo "export K6_CPUS=\"$(topo_count_cpus "$K6").0\""
echo "export ABLATION_CPUSET_NARROW=\"${PY_NARROW}\""
echo "export ABLATION_CPUSET_WIDE=\"${PY_WIDE}\""

# Confirms the recommendation passes the guard that will gate the run, so a value this
# script prints can never be one the suite then refuses.
for svc in "python-service:${PY_WIDE}" "transaction-service:${JAVA}" "k6:${K6}"; do
  verify_service_cpuset "self-check" "${svc%%:*}" "${svc#*:}" "$(topo_count_cpus "${svc#*:}")" > /dev/null
done
echo ""
echo "# Self-check: every cpuset above owns whole physical cores; the blocks are disjoint by construction."