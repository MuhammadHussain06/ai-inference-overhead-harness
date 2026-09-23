"""Thermal and within-cell stationarity analysis shared by analyze-results.py and
analyze-ablation.py.

Reads the env trace both harness scripts write through load-testing/lib/thermal.sh:
temperature and throttle counters at both edges of every measured cell, every
thermal check with the time it paused for, and per-rep environment samples. The
tables built here answer whether temperature or thermal throttling can explain a
latency difference, rather than leaving that as an unexamined threat.
"""

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy import stats

THERMAL_KINDS = ("env_sample", "cell_start", "cell_end", "thermal_check")


def _expand_cpuset(cpuset):
    cpus = set()
    for part in str(cpuset or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            cpus.update(range(int(lo), int(hi) + 1))
        else:
            cpus.add(int(part))
    return cpus


def _number(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return np.nan


def _core_counters(field):
    """"cpu0=12,cpu1=12,..." -> {0: 12.0, 1: 12.0}; empty when not exposed."""
    out = {}
    if not field or field == "na":
        return out
    for pair in field.split(","):
        name, _, value = pair.partition("=")
        if name.startswith("cpu") and name[3:].isdigit():
            out[int(name[3:])] = _number(value)
    return out


def parse_env_trace(path):
    """One row per trace line of a known kind: kind, ts (UTC), temp_c, pkg_throttle_ms,
    core_throttle (dict), and the line's own name -- label for env_sample and
    thermal_check, cell for cell_start/cell_end -- plus paused_s for thermal checks.
    Fields a line does not carry are NaN, which is how a trace written before
    temperatures were recorded reads."""
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            kind, _, rest = line.partition(" ")
            if kind not in THERMAL_KINDS:
                continue
            # Free text (a thermal check's label) is always the last field.
            name = None
            for tail_key in (" label=", " cell="):
                head, sep, tail = (" " + rest).partition(tail_key)
                if sep and kind in ("thermal_check", "cell_start", "cell_end"):
                    name, rest = tail, head
                    break
            fields = dict(tok.split("=", 1) for tok in rest.split() if "=" in tok)
            rows.append({
                "kind": kind,
                "name": name if name is not None else fields.get("label"),
                "ts": pd.to_datetime(fields.get("ts"), utc=True, errors="coerce"),
                "temp_c": _number(fields.get("temp_c")),
                "temp_after_c": _number(fields.get("temp_after_c")),
                "paused_s": _number(fields.get("paused_s")),
                "pkg_throttle_ms": _number(fields.get("pkg_throttle_ms")),
                "core_throttle": _core_counters(fields.get("core_throttle_ms")),
            })
    return pd.DataFrame(rows)


def cell_thermal(trace, service_cpusets):
    """Per measured cell: its duration, temperature at both edges, and the throttling
    accrued during it -- package-level, and per service the most-throttled of its
    CPUs (SMT siblings report one shared core counter, so a sum would count a core
    twice). service_cpusets(cell) -> {service: cpuset string}."""
    if trace is None or trace.empty:
        return pd.DataFrame()
    starts = trace[trace["kind"] == "cell_start"].drop_duplicates("name", keep="last").set_index("name")
    ends = trace[trace["kind"] == "cell_end"].drop_duplicates("name", keep="last").set_index("name")
    rows = []
    for cell in (c for c in ends.index if c in starts.index):
        s, e = starts.loc[cell], ends.loc[cell]
        row = {
            "cell": cell,
            "duration_s": (e["ts"] - s["ts"]).total_seconds() if pd.notna(e["ts"]) and pd.notna(s["ts"]) else np.nan,
            "temp_start_c": s["temp_c"],
            "temp_end_c": e["temp_c"],
            "pkg_throttle_ms": e["pkg_throttle_ms"] - s["pkg_throttle_ms"],
        }
        for service, cpuset in service_cpusets(cell).items():
            deltas = [e["core_throttle"][c] - s["core_throttle"][c] for c in _expand_cpuset(cpuset)
                      if c in e["core_throttle"] and c in s["core_throttle"]]
            row[f"{service}_throttle_ms"] = max(deltas) if deltas else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


def thermal_by_group(cells, group_of, services, label_of=str, sort_key=None):
    """Summarizes cell_thermal() rows per group_of(cell) (None drops the cell), labelled
    by label_of(group) and ordered by sort_key(group), or in first-seen order."""
    if cells is None or cells.empty:
        return pd.DataFrame()
    groups = {}
    for i, cell in enumerate(cells["cell"]):
        key = group_of(cell)
        if key is not None:
            groups.setdefault(key, []).append(i)
    throttle_cols = [f"{s}_throttle_ms" for s in services if f"{s}_throttle_ms" in cells]
    rows = []
    for group in (sorted(groups, key=sort_key) if sort_key else groups):
        g = cells.iloc[groups[group]]
        row = {
            "Group": label_of(group),
            "Cells": len(g),
            "Median start temp (C)": _round(g["temp_start_c"].median()),
            "Median end temp (C)": _round(g["temp_end_c"].median()),
            "Max end temp (C)": _round(g["temp_end_c"].max()),
        }
        throttled = g[throttle_cols].fillna(0).gt(0).any(axis=1) if throttle_cols else pd.Series(dtype=bool)
        known = g[throttle_cols].notna().any(axis=1) if throttle_cols else pd.Series(dtype=bool)
        row["Cells throttled on service cores"] = (
            f"{int(throttled[known].sum())}/{int(known.sum())}" if known.any() else "not exposed")
        for col in throttle_cols:
            label = col.replace("_throttle_ms", "")
            row[f"Max {label} core throttle (ms)"] = _round(g[col].max())
        row["Max package throttle (ms)"] = _round(g["pkg_throttle_ms"].max())
        rows.append(row)
    return pd.DataFrame(rows)


def thermal_pauses(trace, phase_of):
    """Per phase: thermal checks run, how many paused, and the total time paused."""
    if trace is None or trace.empty:
        return pd.DataFrame()
    checks = trace[trace["kind"] == "thermal_check"]
    if checks.empty:
        return pd.DataFrame()
    checks = checks.assign(phase=checks["name"].map(phase_of).fillna("other"))
    rows = []
    for phase, g in checks.groupby("phase", sort=False):
        paused = g[g["paused_s"].fillna(0) > 0]
        rows.append({
            "Phase": phase,
            "Thermal checks": len(g),
            "Checks that paused": len(paused),
            "Total paused (min)": round(float(g["paused_s"].fillna(0).sum()) / 60, 1),
            "Max temp at check (C)": _round(g["temp_c"].max()),
        })
    return pd.DataFrame(rows)


def thermal_latency_association(cells, latency):
    """Spearman correlation between each cell's thermal state and its latency, taken
    as the cell's percent deviation from its own group's mean across reps, so the
    between-group latency differences the design manipulates do not register as a
    thermal effect. latency: cell, group, mean_ms."""
    if cells is None or cells.empty or latency is None or latency.empty:
        return pd.DataFrame()
    merged = latency.merge(cells, on="cell", how="inner")
    if merged.empty:
        return pd.DataFrame()
    group_mean = merged.groupby("group")["mean_ms"].transform("mean")
    merged["deviation_pct"] = 100 * (merged["mean_ms"] / group_mean - 1)
    candidates = [("Temperature at cell start (C)", "temp_start_c"),
                  ("Temperature at cell end (C)", "temp_end_c"),
                  ("Package throttle during cell (ms)", "pkg_throttle_ms")]
    candidates += [(f"{c.replace('_throttle_ms', '')} core throttle during cell (ms)", c)
                   for c in merged.columns if c.endswith("_throttle_ms") and c != "pkg_throttle_ms"]
    rows = []
    for label, col in candidates:
        pair = merged[[col, "deviation_pct"]].dropna()
        row = {"Thermal variable": label, "Cells": len(pair)}
        if len(pair) >= 3 and pair[col].nunique() > 1:
            rho, p = stats.spearmanr(pair[col], pair["deviation_pct"])
            row.update({"Spearman rho": round(float(rho), 3), "p-value": _fmt_p(p)})
        else:
            row.update({"Spearman rho": np.nan,
                        "p-value": "constant" if len(pair) >= 3 else "too few cells"})
        rows.append(row)
    return pd.DataFrame(rows)


def within_cell_drift(groups, min_points=20):
    """How much latency moved between the first and second half of each cell, in
    time, summarized per group. groups: (label, frame) pairs in reporting order,
    each frame holding one group's points with rep, time and value. A change of the
    same sign in every rep is heat soak, queue build-up or the closed-loop taper at
    the cell's end rather than noise, and means the reported mean depends on how
    long the cell ran."""
    rows = []
    for label, g in groups:
        changes = []
        for _, cell in g.groupby("rep", observed=True):
            cell = cell.dropna(subset=["time", "value"])
            if len(cell) < min_points:
                continue
            t = cell["time"]
            mid = t.min() + (t.max() - t.min()) / 2
            first, second = cell.loc[t <= mid, "value"], cell.loc[t > mid, "value"]
            if first.empty or second.empty or first.mean() == 0:
                continue
            changes.append(100 * (second.mean() / first.mean() - 1))
        if not changes:
            continue
        changes = np.asarray(changes)
        row = {"Group": label, "Cells": len(changes),
               "Mean 2nd-half vs 1st-half change (%)": round(float(changes.mean()), 2)}
        if len(changes) >= 2:
            half = stats.t.ppf(0.975, len(changes) - 1) * changes.std(ddof=1) / np.sqrt(len(changes))
            row["95% CI"] = f"[{changes.mean() - half:.2f}, {changes.mean() + half:.2f}]"
            row["Same sign in every cell"] = "yes" if (np.all(changes > 0) or np.all(changes < 0)) else "no"
        else:
            row["95% CI"] = "n/a (needs >=2 cells)"
            row["Same sign in every cell"] = "n/a"
        rows.append(row)
    return pd.DataFrame(rows)


def timeline_figure(trace, phase_of, title):
    """Temperature over the run: every cell edge and thermal check, colored by phase,
    with the checks that paused marked. None when the trace has no temperatures."""
    if trace is None or trace.empty:
        return None
    pts = trace.dropna(subset=["ts", "temp_c"])
    if pts.empty:
        return None
    t0 = pts["ts"].min()
    pts = pts.assign(elapsed_min=(pts["ts"] - t0).dt.total_seconds() / 60,
                     phase=pts["name"].map(phase_of).fillna("other"))
    fig, ax = plt.subplots(figsize=(10, 4), dpi=300)
    for phase, g in pts.groupby("phase", sort=False):
        ax.scatter(g["elapsed_min"], g["temp_c"], s=4, label=phase)
    paused = pts[(pts["kind"] == "thermal_check") & (pts["paused_s"].fillna(0) > 0)]
    if not paused.empty:
        ax.scatter(paused["elapsed_min"], paused["temp_c"], s=18, marker="x", color="black",
                   label="check that paused")
    ax.set_xlabel("Elapsed time (min)")
    ax.set_ylabel("Highest thermal-zone temperature (C)")
    ax.set_title(title, fontweight="bold")
    ax.legend(fontsize=7, markerscale=2)
    ax.grid(True, linestyle="--", alpha=0.4)
    return fig


def _round(v, digits=1):
    return round(float(v), digits) if pd.notna(v) else np.nan


def _fmt_p(p):
    return f"{p:.2e}" if p < 0.001 else round(float(p), 4)
