#!/usr/bin/env bash
# Run directories and run identity shared by run-suite.sh and run-ablation.sh.
#
# Each invocation writes into results/<kind>_<host>_<UTC timestamp>/. A new run supersedes
# the same machine's previous run of the same kind, which moves to results/archive/; runs of
# the other kind, and runs copied in from other machines, stay in place so the analysis can
# read them together.

# Hostname lowercased and reduced to [a-z0-9.-], so it sits unambiguously between the
# underscores of a run directory name.
run_host_label() {
  local h
  h=$(uname -n 2>/dev/null || echo "")
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-' | sed 's/^-*//; s/-*$//')
  printf '%s' "${h:-unknown-host}"
}

# First 12 hex digits of the SHA-256 of the machine ID: tells apart machines that share a
# hostname without recording the ID itself.
machine_id_hash() {
  local f
  for f in /etc/machine-id /var/lib/dbus/machine-id; do
    if [ -s "$f" ] && [ -r "$f" ]; then
      sha256sum < "$f" | cut -c1-12
      return 0
    fi
  done
  printf 'unknown'
}

# The machine_id_hash a run directory's metadata records; empty when it records none.
recorded_machine_id() {
  local f
  for f in "$1/run_metadata.json" "$1/ablation_run_metadata.json"; do
    if [ -f "$f" ]; then
      sed -n '/"machine_id_hash"/{s/.*"machine_id_hash": *"\([^"]*\)".*/\1/p;q;}' "$f"
      return 0
    fi
  done
}

# UTC, so run directories from hosts in different time zones order correctly.
run_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

# Moves every earlier <kind> run of this machine from results_root into
# results_root/archive/, suffixing a name that is already taken there rather than nesting
# into it. A run whose metadata records a different machine under the same hostname stays.
archive_superseded_runs() {
  local results_root="$1" kind="$2" host="$3" machine="$4" dir name dest n recorded
  for dir in "${results_root}/${kind}_${host}_"*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    recorded=$(recorded_machine_id "$dir")
    if [ -n "$recorded" ] && [ "$recorded" != "unknown" ] && [ "$machine" != "unknown" ] \
        && [ "$recorded" != "$machine" ]; then
      echo "[*] Left ${name} in place: recorded on another machine named ${host}"
      continue
    fi
    mkdir -p "${results_root}/archive"
    dest="${results_root}/archive/${name}"
    n=1
    while [ -e "$dest" ]; do
      dest="${results_root}/archive/${name}.${n}"
      n=$((n + 1))
    done
    mv "$dir" "$dest"
    echo "[*] Archived superseded run ${name} to ${dest}"
  done
}

# Moves the files a pre-v1.2 <kind> run left directly in results_root into
# results_root/archive/<timestamp>/ (suite) or <timestamp>_ablation/ (ablation). ablation_*
# files are the ablation's; every other top-level result file is the suite's, except the
# probes' output: probe_* and calib_*.json (the suite's own calib_* files are gzipped).
archive_flat_layout() {
  local results_root="$1" kind="$2" dest suffix=""
  local -a match
  if [ "$kind" = "ablation" ]; then
    match=(-name 'ablation_*' \( -name '*.json' -o -name '*.json.gz' -o -name '*_log.txt' \))
    suffix="_ablation"
  else
    match=(! -name 'ablation_*' ! -name 'probe_*' ! \( -name 'calib_*' -name '*.json' \)
           \( -name '*.json' -o -name '*.json.gz' -o -name '*_log.txt' \))
  fi
  [ -n "$(find "$results_root" -maxdepth 1 -type f "${match[@]}" -print -quit)" ] || return 0
  dest="${results_root}/archive/$(date +%Y%m%d_%H%M%S)${suffix}"
  mkdir -p "$dest"
  find "$results_root" -maxdepth 1 -type f "${match[@]}" -exec mv {} "$dest/" \;
  if [ "$kind" = "suite" ] && [ -n "$(ls -A "${results_root}/gc-logs" 2>/dev/null)" ]; then
    mv "${results_root}/gc-logs" "${dest}/gc-logs"
    mkdir -p "${results_root}/gc-logs"
  fi
  echo "[*] Archived flat-layout ${kind} results to ${dest}"
}

# Sets RUN_ID and RESULTS_DIR for a new <kind> run under results_root, after archiving this
# host's earlier runs of that kind and any flat-layout leftovers. RESULTS_DIR_OVERRIDE names
# the run directory instead and archives nothing, which keeps the fault-injection suite's
# cases out of the real dataset.
prepare_run_dir() {
  local results_root="$1" kind="$2" host
  if [ -n "${RESULTS_DIR_OVERRIDE:-}" ]; then
    RESULTS_DIR="$RESULTS_DIR_OVERRIDE"
    RUN_ID=$(basename "$RESULTS_DIR")
    return 0
  fi
  mkdir -p "$results_root"
  archive_flat_layout "$results_root" "$kind"
  host=$(run_host_label)
  archive_superseded_runs "$results_root" "$kind" "$host" "$(machine_id_hash)"
  RUN_ID="${kind}_${host}_$(run_timestamp)"
  RESULTS_DIR="${results_root}/${RUN_ID}"
}

# SHA-256 over the working-tree content of every tracked file that shapes a measurement:
# the compose file, both services and the load-testing harness, excluding their tests,
# the probes and model training. Equal fingerprints mean identical tracked measured code
# whatever the commit or uncommitted edits; untracked files are not covered, and git_dirty
# records their presence.
measurement_fingerprint() {
  local root="$1" files
  files=$(git -C "$root" ls-files -- docker-compose.yml services load-testing \
    ':!load-testing/tests' ':!load-testing/probing' ':!services/fraud-ml-service/tests' \
    ':!services/fraud-ml-service/training' ':!services/transaction-service/src/test' 2>/dev/null || true)
  if [ -z "$files" ]; then
    printf 'unknown (not a git checkout)'
    return 0
  fi
  (
    cd "$root" || exit 1
    LC_ALL=C sort <<< "$files" | while IFS= read -r f; do
      if [ -f "$f" ]; then sha256sum -- "$f"; fi
    done
  ) | sha256sum | cut -d' ' -f1
}
