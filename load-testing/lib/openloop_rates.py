#!/usr/bin/env python3
"""Closed-loop throughput of one target at the highest concurrency level of a suite
run's scan, the plateau run-openloop.sh sets its arrival rates against.

    openloop_rates.py RUN_DIR TARGET

Prints "<vus> <req/s>": per rep, (N-1)/span over the cell's HTTP 200 completion
times, then the mean across reps -- the convention of analyze-results.py's table 4.
Exits non-zero when the run holds no scan cell for TARGET.
"""

import gzip
import json
import os
import re
import sys

from warmup_gate import ts_seconds

_METRIC_MARK = '"http_req_duration"'


def cell_throughput(path):
    """(N-1)/span of one cell file's HTTP 200 scan completions, or None below two."""
    first = last = None
    n = 0
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        for line in f:
            if _METRIC_MARK not in line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") != "Point" or obj.get("metric") != "http_req_duration":
                continue
            data = obj.get("data") or {}
            tags = data.get("tags") or {}
            if tags.get("status") != "200" or tags.get("phase") != "scan" or data.get("time") is None:
                continue
            t = ts_seconds(data["time"])
            first = t if first is None else min(first, t)
            last = t if last is None else max(last, t)
            n += 1
    if n < 2 or last <= first:
        return None
    return (n - 1) / (last - first)


def plateau(run_dir, target):
    """(vus, mean req/s across reps) at the target's highest scanned level."""
    pattern = re.compile(rf"^scan_{re.escape(target)}_vus(\d+)_rep\d+\.json(?:\.gz)?$")
    cells = {}
    for name in os.listdir(run_dir):
        m = pattern.match(name)
        if m:
            cells.setdefault(int(m[1]), []).append(os.path.join(run_dir, name))
    if not cells:
        return None
    vus = max(cells)
    rates = [r for r in (cell_throughput(p) for p in sorted(cells[vus])) if r is not None]
    return (vus, sum(rates) / len(rates)) if rates else None


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    result = plateau(argv[1], argv[2])
    if result is None:
        sys.exit(f"No usable scan_{argv[2]}_vus*_rep* cell in {argv[1]}")
    print(f"{result[0]} {result[1]:.1f}")


if __name__ == "__main__":
    main(sys.argv)
