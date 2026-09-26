"""Run directories under results/: discovery, identity, and the output folders each
analysis script writes to.

run-suite.sh and run-ablation.sh write one directory per invocation,
results/<kind>_<host>_<UTC timestamp>/. A directory is a run of a kind when it holds
that kind's metadata or result files. results/ itself qualifies when it holds them
directly, which is how runs recorded before v1.2 are laid out.
"""

import json
import os
import re
import shutil
from typing import NamedTuple

KINDS = ("suite", "ablation")
METADATA_FILE = {"suite": "run_metadata.json", "ablation": "ablation_run_metadata.json"}
RESULT_FILE_RE = {
    "suite": re.compile(r"^(?:baseline|scan|openloop|warmup)_.+\.json(?:\.gz)?$"),
    "ablation": re.compile(r"^ablation_.+_rep\d+\.json(?:\.gz)?$"),
}
# Subdirectories that hold a run's scratch or logs, or superseded runs, never a run of their own.
NON_RUN_SUBDIRS = {"archive", "raw", "gc-logs", "probes"}
RUN_DIR_RE = re.compile(r"^(?P<kind>suite|ablation)_(?P<host>[a-z0-9.-]+)_(?P<ts>\d{8}T\d{6}Z)$")
# Keeps a joined run-label list inside common file-name limits.
MAX_SUFFIX_LABEL_CHARS = 150


def host_label(name):
    """Lowercased and reduced to [a-z0-9.-], matching lib/run-layout.sh's run_host_label."""
    label = re.sub(r"[^a-z0-9.-]", "-", str(name or "").lower()).strip("-")
    return label or "unknown-host"


def read_metadata(path, kind):
    """The run's metadata file, or {} when absent or unreadable."""
    fp = os.path.join(path, METADATA_FILE[kind])
    if not os.path.isfile(fp):
        return {}
    try:
        with open(fp) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"[!] {fp} could not be read ({e}); identity and recorded parameters fall back to defaults.")
        return {}


def _hostname_of(metadata):
    if metadata.get("hostname"):
        return metadata["hostname"]
    fields = str(metadata.get("host_uname", "")).split()
    return fields[1] if len(fields) > 1 else None


def _compact_timestamp(iso):
    digits = re.sub(r"\D", "", str(iso or ""))
    return f"{digits[:8]}T{digits[8:14]}Z" if len(digits) >= 14 else None


class Run:
    """One run directory: its kind, path, metadata and identity."""

    def __init__(self, kind, path):
        self.kind = kind
        self.path = os.path.normpath(path)
        self.metadata = read_metadata(path, kind)
        dir_match = RUN_DIR_RE.match(os.path.basename(self.path))
        run_id_match = RUN_DIR_RE.match(str(self.metadata.get("run_id", "")))
        hostname = _hostname_of(self.metadata)
        if hostname is None and kind == "ablation":
            # Pre-v1.2 ablation metadata records no host; in the flat layout the suite's
            # metadata beside it came from the same machine.
            hostname = _hostname_of(read_metadata(path, "suite"))
        if hostname is not None:
            self.host = host_label(hostname)
        elif dir_match:
            self.host = dir_match.group("host")
        else:
            self.host = "unknown-host"
        ts_match = run_id_match or dir_match
        machine = self.metadata.get("machine_id_hash")
        self.machine = machine if machine not in (None, "", "unknown") else None
        self.timestamp = (ts_match.group("ts") if ts_match
                          else _compact_timestamp(self.metadata.get("timestamp_utc")) or "unknown-time")
        self.name = (run_id_match.group(0) if run_id_match
                     else f"{kind}_{self.host}_{self.timestamp}")

    def __repr__(self):
        return f"Run({self.name}, {self.path})"


def is_run_dir(path, kind):
    if os.path.isfile(os.path.join(path, METADATA_FILE[kind])):
        return True
    try:
        return any(RESULT_FILE_RE[kind].match(n) for n in os.listdir(path))
    except OSError:
        return False


def resolve(paths, kind):
    """Runs of this kind in each path: the path itself when it is one, and each of its
    subdirectories that is, other than NON_RUN_SUBDIRS. Sorted by host and time. Raises
    ValueError for a missing path or two directories with the same identity."""
    found = {}
    for root in paths:
        if not os.path.isdir(root):
            raise ValueError(f"{root} is not a directory.")
        candidates = [root] + [os.path.join(root, e) for e in sorted(os.listdir(root))
                               if e not in NON_RUN_SUBDIRS and os.path.isdir(os.path.join(root, e))]
        for path in candidates:
            if is_run_dir(path, kind):
                found.setdefault(os.path.realpath(path), Run(kind, path))
    runs = sorted(found.values(), key=lambda r: (r.host, r.timestamp, r.path))
    names = {}
    for run in runs:
        if run.name in names:
            raise ValueError(f"{names[run.name]} and {run.path} both identify as {run.name}; "
                             f"analyze them separately or remove the duplicate.")
        names[run.name] = run.path
    return runs


class OutputDirs(NamedTuple):
    """Where one set of tables and figures goes; suffix is appended to every file name."""
    tables: str
    figures: str
    suffix: str = ""


def as_output_dirs(out):
    """out as OutputDirs; a plain directory holds tables/ and figures/ directly."""
    if isinstance(out, OutputDirs):
        return out
    return OutputDirs(os.path.join(out, "tables"), os.path.join(out, "figures"))


def prepare_run_outputs(output_root, kind, runs):
    """Removes every <kind>_* folder under output_root/tables and output_root/figures, and
    files the pre-v1.2 layout wrote directly into them, then maps each run's name to the
    folders its outputs go in."""
    for sub in ("tables", "figures"):
        base = os.path.join(output_root, sub)
        if not os.path.isdir(base):
            continue
        for entry in os.listdir(base):
            path = os.path.join(base, entry)
            if os.path.isdir(path) and entry.startswith(f"{kind}_"):
                shutil.rmtree(path)
            elif os.path.isfile(path):
                os.remove(path)
    return {run.name: OutputDirs(os.path.join(output_root, "tables", run.name),
                                 os.path.join(output_root, "figures", run.name)) for run in runs}


def prepare_hostvariance_outputs(output_root, file_prefixes, labels, date):
    """Removes this script's earlier files from output_root/hostvariance/{tables,figures}
    and returns the OutputDirs its files go through, suffixed with the compared runs'
    labels and the analysis date."""
    out = OutputDirs(os.path.join(output_root, "hostvariance", "tables"),
                     os.path.join(output_root, "hostvariance", "figures"))
    for base in (out.tables, out.figures):
        if not os.path.isdir(base):
            continue
        for entry in os.listdir(base):
            if entry.startswith(tuple(file_prefixes)) and os.path.isfile(os.path.join(base, entry)):
                os.remove(os.path.join(base, entry))
    joined = "_".join(labels)
    runs = joined if len(joined) <= MAX_SUFFIX_LABEL_CHARS else f"{len(labels)}runs"
    return out._replace(suffix=f"_{runs}_{date}")
