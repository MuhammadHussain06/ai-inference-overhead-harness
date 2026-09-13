#!/usr/bin/env bash
# One-shot setup for every *test* dependency across the repo -- as opposed to
# setup.sh, which only sets up what's needed to actually run the measurement
# stack for real numbers (.env, results/gc-logs, analysis/venv). Safe to re-run.
#
# Covers, in order:
#   - Java:          transaction-service's JDK (Maven itself and its test deps
#                    -- JUnit, spring-boot-starter-test, reactor-test -- are
#                    fetched automatically by ./mvnw on first `./mvnw test`,
#                    so there's nothing else to pre-install there).
#   - Python/analysis:      analysis/venv, from analysis/requirements.txt +
#                    analysis/requirements-dev.txt (pytest, for analysis/tests/).
#   - Python/fraud-ml:      services/fraud-ml-service/.venv, from its own
#                    requirements-dev.txt (pytest + httpx, on top of the
#                    service's real requirements.txt).
#   - Bash/load-testing:    bats-core, for load-testing/tests/*.bats.
#
# Usage: ./install-test-deps.sh   (run from the repo root)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MIN_BATS_MAJOR=1
MIN_BATS_MINOR=5
MIN_JAVA_MAJOR=21

# ---------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Runs an apt-get install non-interactively as root if we already are root,
# via sudo if that's available, or not at all -- printing why -- otherwise.
# Returns 1 without attempting anything if neither path is available.
apt_install() {
  if ! have apt-get; then
    return 1
  fi
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update -qq || true
    apt-get install -y "$@"
  elif have sudo; then
    sudo apt-get update -qq || true
    sudo apt-get install -y "$@"
  else
    echo "  no sudo on PATH and not running as root -- can't apt install $* non-interactively." >&2
    return 1
  fi
}

# Picks python3.11 when it's available (the version this repo's pandas/xgboost
# pins are known to build cleanly against) over a bare `python3`, which on a
# fresh Ubuntu 24.04+ box can resolve to something too new to have prebuilt
# wheels for pandas==2.2.2 -- forcing a source build that fails outright under
# newer GCC. Falls back to installing python3.11 via apt, then to plain
# python3 with a warning, rather than failing outright.
pick_python() {
  if have python3.11; then
    echo "python3.11"
    return
  fi
  echo "  python3.11 not found -- trying to install it (avoids a known pandas/xgboost" \
       "source-build failure against very new Python versions)." >&2
  if apt_install python3.11 python3.11-venv >&2 && have python3.11; then
    echo "python3.11"
    return
  fi
  echo "  could not get python3.11 -- falling back to plain python3. If dependency" \
       "installation below fails on a pandas or xgboost build step, that's this exact" \
       "issue; installing python3.11 yourself and re-running is the fix." >&2
  echo "python3"
}

# Builds (or reuses) a venv at $1 with the given python, then pip-installs
# every requirements file passed after it. Always re-runs pip install even if
# the venv already existed, so a changed requirements file is picked up.
build_venv() {
  local venv_dir="$1" python_bin="$2"
  shift 2
  if [ ! -d "$venv_dir" ]; then
    "$python_bin" -m venv "$venv_dir"
    echo "  created $venv_dir ($("$python_bin" --version))"
  else
    echo "  reusing $venv_dir"
  fi
  "$venv_dir/bin/pip" install -q --upgrade pip
  for req in "$@"; do
    "$venv_dir/bin/pip" install -q -r "$req"
  done
}

# ---------------------------------------------------------------------------
# Java: transaction-service
# ---------------------------------------------------------------------------

echo "== Java (transaction-service, needs JDK ${MIN_JAVA_MAJOR}+) =="
java_major=""
if have java; then
  java_major=$(java -version 2>&1 | grep -o '"[0-9]\+' | head -1 | tr -d '"')
fi
if [ -n "$java_major" ] && [ "$java_major" -ge "$MIN_JAVA_MAJOR" ]; then
  echo "  found: $(java -version 2>&1 | grep -m1 'version')"
else
  echo "  missing or older than ${MIN_JAVA_MAJOR} -- installing openjdk-${MIN_JAVA_MAJOR}-jdk."
  if apt_install "openjdk-${MIN_JAVA_MAJOR}-jdk"; then
    echo "  installed: $(java -version 2>&1 | grep -m1 'version')"
  else
    echo "  could not install a JDK automatically -- install JDK ${MIN_JAVA_MAJOR}+ yourself" \
         "and re-run this script." >&2
    exit 1
  fi
fi
echo "  Maven itself and transaction-service's test deps (JUnit, spring-boot-starter-test," \
     "reactor-test) are fetched by ./mvnw on first \`cd services/transaction-service && ./mvnw test\` --" \
     "nothing more to pre-install here."

# ---------------------------------------------------------------------------
# Python: analysis
# ---------------------------------------------------------------------------

echo
echo "== Python (analysis/) =="
analysis_python=$(pick_python)
build_venv analysis/venv "$analysis_python" analysis/requirements.txt analysis/requirements-dev.txt
echo "  analysis/venv ready ($analysis_python)."

# ---------------------------------------------------------------------------
# Python: fraud-ml-service
# ---------------------------------------------------------------------------

echo
echo "== Python (services/fraud-ml-service/) =="
fraudml_python=$(pick_python)
build_venv services/fraud-ml-service/.venv "$fraudml_python" services/fraud-ml-service/requirements-dev.txt
echo "  services/fraud-ml-service/.venv ready ($fraudml_python)."

# ---------------------------------------------------------------------------
# Bash: load-testing
# ---------------------------------------------------------------------------

echo
echo "== bats-core (load-testing/tests/*.bats) =="

version_ok() {
  local ver="$1" major minor
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt "$MIN_BATS_MAJOR" ] && return 0
  [ "$major" -eq "$MIN_BATS_MAJOR" ] && [ "$minor" -ge "$MIN_BATS_MINOR" ]
}

resolved_bats_version() {
  hash -r 2>/dev/null || true
  have bats || { echo ""; return; }
  bats --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || true
}

current_ver=$(resolved_bats_version)
if [ -n "$current_ver" ] && version_ok "$current_ver"; then
  echo "  already installed: $(bats --version) at $(command -v bats)."
else
  if [ -n "$current_ver" ]; then
    echo "  found bats $current_ver on PATH, older than ${MIN_BATS_MAJOR}.${MIN_BATS_MINOR}.0 -- upgrading."
  else
    echo "  not found -- installing."
  fi

  installed=0
  if apt_install bats; then
    current_ver=$(resolved_bats_version)
    if [ -n "$current_ver" ] && version_ok "$current_ver"; then
      echo "  apt installed $(bats --version) at $(command -v bats)."
      installed=1
    else
      echo "  apt's bats is still unusable ($( [ -n "$current_ver" ] && echo "$current_ver" || echo "not runnable" )) --" \
           "something earlier in PATH may be shadowing it, or the package is too old." \
           " Falling back to building from source."
    fi
  fi

  if [ "$installed" -eq 0 ]; then
    tmp_clone=$(mktemp -d)
    trap 'rm -rf "$tmp_clone"' EXIT
    git clone --depth 1 https://github.com/bats-core/bats-core.git "$tmp_clone" >/dev/null
    if [ "$(id -u)" -eq 0 ]; then
      "$tmp_clone"/install.sh /usr/local
    elif have sudo; then
      sudo "$tmp_clone"/install.sh /usr/local
    else
      echo "  not root and no sudo on PATH -- can't install to /usr/local. Install JDK" \
           "manually or install bats-core to a directory already on PATH." >&2
      exit 1
    fi
    new_ver=""
    [ -x /usr/local/bin/bats ] && new_ver=$(/usr/local/bin/bats --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || true)
    if [ -z "$new_ver" ] || ! version_ok "$new_ver"; then
      echo "  install.sh ran but /usr/local/bin/bats doesn't report a usable version." >&2
      exit 1
    fi
    current_ver=$(resolved_bats_version)
    if [ "$current_ver" = "$new_ver" ] && [ "$(command -v bats)" = "/usr/local/bin/bats" ]; then
      echo "  installed: $(bats --version) at /usr/local/bin/bats."
    else
      echo "  installed bats-core ${new_ver} to /usr/local/bin/bats, but PATH still resolves" \
           "'bats' to $(command -v bats 2>/dev/null || echo '(nothing)') instead -- put" \
           "/usr/local/bin ahead of that entry in PATH, or invoke /usr/local/bin/bats directly." >&2
      exit 1
    fi
  fi
fi

missing=()
for tool in bash awk sed grep cut tr sort paste shuf mktemp; do
  have "$tool" || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "  MISSING: ${missing[*]} -- these ship with coreutils/bash on every mainstream" \
       "Linux distro; install your distro's coreutils package and re-run this script." >&2
  exit 1
fi
echo "  docker not required for these tests -- test_jvm_pins.bats and the" \
     "compose_service_value tests stub it out on PATH."

echo
cat <<'EOF'
Ready. Run each area's tests with:
    cd services/transaction-service && ./mvnw test
    analysis/venv/bin/pytest analysis/tests/
    services/fraud-ml-service/.venv/bin/pytest services/fraud-ml-service/tests/
    cd load-testing && bats tests/
EOF