"""Between-rep outlier cells in the concurrency scan, and the connection-to-worker
placement that explains them.

A scan cell is flagged when its mean latency sits far above its design cell's other
reps: modified z-score (median/MAD) above Z_THRESHOLD and at least MIN_DEVIATION_PCT
above the median rep. Each cell carries the features that tell the candidate causes
apart: whether the whole distribution moved (median shift) or only its start (first
tenth of requests against the rest), Python compute stall and thread dispatch, thermal
throttling, and, from lib/placement.py's log, how its connections were spread across
the python-service workers.

A placement's crowding is the number of connections on the worker serving a connection,
itself included, averaged over connections: sum(c_i^2) / sum(c_i) for worker counts c_i.
Requests on one worker contend for its GIL, so crowding is what a request experiences.
The most even split of a cell's connections has the lowest crowding possible for its
connection and worker counts; a placement is compared by its crowding above that.
"""

import os
import re

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

Z_THRESHOLD = 3.5
MIN_DEVIATION_PCT = 5.0
PLACEMENT_LOG = "connection_placement_log.txt"
SCAN_CELL_RE = re.compile(r"^scan_(?P<tier>[a-z0-9]+)_vus(?P<vus>\d+)_rep(?P<rep>\d+)$")
STALL, DISPATCH = "python_compute_stall_time_ms", "python_thread_dispatch_time_ms"
BRIDGE = "java_estimated_bridge_overhead_ms"
_FIELD_RE = re.compile(r"(\w+)=(\S+)")


def _cell_name(source):
    return re.sub(r"\.json(?:\.gz)?$", "", str(source))


def cell_features(df):
    """One row per scan cell: its design cell, mean and median HTTP 200 latency, the
    mean of its first tenth of requests over the rest (in completion order), and its
    mean compute stall, thread dispatch and bridge overhead."""
    scan = df[df["phase"] == "scan"]
    ok = scan[(scan["metric"] == "http_req_duration") & (scan["status"] == "200")]
    rows = {}
    for source, cell in ok.groupby("source_file", observed=True):
        name = _cell_name(source)
        m = SCAN_CELL_RE.match(name)
        if not m or cell.empty:
            continue
        v = cell.sort_values("time")["value"].to_numpy(dtype=float)
        k = max(1, len(v) // 10)
        rows[str(source)] = {
            "cell": name, "tier": m["tier"], "vus": int(m["vus"]), "rep": m["rep"],
            "mean": float(v.mean()), "median": float(np.median(v)),
            "first_tenth_ratio": float(v[:k].mean() / v[k:].mean()) if len(v) > k else np.nan,
        }
    cells = pd.DataFrame(rows.values(), index=list(rows))
    if cells.empty:
        return cells
    stages = (scan[scan["metric"].isin([STALL, DISPATCH, BRIDGE])]
              .groupby(["source_file", "metric"], observed=True)["value"].mean().unstack())
    stages.index = stages.index.astype(str)
    for metric, col in ((STALL, "stall_ms"), (DISPATCH, "dispatch_ms"), (BRIDGE, "bridge_ms")):
        cells[col] = stages[metric].reindex(cells.index) if metric in stages else np.nan
    return cells.reset_index(drop=True)


def flag_outliers(cells):
    """Adds each cell's deviation from its design cell's median rep, its modified
    z-score, its median's shift against the median rep, and the flag."""
    cells = cells.copy()
    grouped = cells.groupby(["tier", "vus"])
    median = grouped["mean"].transform("median")
    mad = grouped["mean"].transform(lambda s: float(np.median(np.abs(s - s.median()))))
    cells["deviation_pct"] = 100 * (cells["mean"] / median - 1)
    cells["modified_z"] = np.where(mad > 0, 0.6745 * (cells["mean"] - median) / mad.where(mad > 0, 1), 0.0)
    cells["median_shift_pct"] = 100 * (cells["median"] / grouped["median"].transform("median") - 1)
    cells["flagged"] = (cells["modified_z"] > Z_THRESHOLD) & (cells["deviation_pct"] >= MIN_DEVIATION_PCT)
    for col in ("stall_ms", "dispatch_ms"):
        unflagged = cells[col].where(~cells["flagged"])
        cells[f"{col}_others"] = unflagged.groupby([cells["tier"], cells["vus"]]).transform("median")
    return cells


def crowding(counts):
    """sum(c^2) / sum(c): connections on the worker serving a connection, itself included."""
    total = sum(counts)
    return sum(c * c for c in counts) / total if total else float("nan")


def even_crowding(connections, workers):
    """Crowding of the most even split of connections across workers."""
    q, extra = divmod(connections, workers)
    return crowding([q + 1] * extra + [q] * (workers - extra))


def parse_placement_log(results_dir):
    """Per cell, its placement from the log: the state it held longest while at least
    one connection was open, with its crowding above the most even split. Returns None
    when the run has no log."""
    path = os.path.join(results_dir, PLACEMENT_LOG)
    if not os.path.isfile(path):
        return None
    events = {}
    with open(path) as f:
        for line in f:
            kind, _, rest = line.strip().partition(" ")
            fields = dict(_FIELD_RE.findall(rest))
            if "cell" in fields and kind in ("placement", "placement_end", "placement_unavailable"):
                events.setdefault(fields["cell"], []).append((kind, fields))
    rows = []
    for cell, evs in events.items():
        row = {"cell": cell, "placement": "unrecorded", "established": np.nan, "workers": np.nan,
               "crowding": np.nan, "crowding_above_even": np.nan}
        unavailable = [f.get("reason", "") for k, f in evs if k == "placement_unavailable"]
        if unavailable:
            row["placement"] = f"unavailable ({unavailable[0]})"
            rows.append(row)
            continue
        times = [pd.Timestamp(f["ts"]) for _, f in evs]
        held = {}
        for i, (kind, f) in enumerate(evs):
            if kind != "placement" or i + 1 >= len(evs) or int(f.get("established", 0)) < 1:
                continue
            counts = tuple(sorted((int(p.split(":")[1]) for p in f.get("workers", "").split(",") if ":" in p),
                                  reverse=True))
            held[counts] = held.get(counts, 0.0) + (times[i + 1] - times[i]).total_seconds()
        if held:
            counts = max(held, key=held.get)
            total, n_workers = sum(counts), len(counts)
            row.update(placement="-".join(map(str, counts)), established=total, workers=n_workers)
            if total and n_workers:
                row.update(crowding=round(crowding(counts), 3),
                           crowding_above_even=round(crowding(counts) - even_crowding(total, n_workers), 3))
        rows.append(row)
    return pd.DataFrame(rows)


def outlier_table(cells, thermal_cells=None):
    """The flagged cells with the features that tell their cause apart."""
    flagged = cells[cells["flagged"]].copy()
    if flagged.empty:
        return pd.DataFrame()
    if thermal_cells is not None and not thermal_cells.empty:
        keep = [c for c in ("cell", "temp_start_c", "python_throttle_ms", "python_mhz") if c in thermal_cells]
        flagged = flagged.merge(thermal_cells[keep], on="cell", how="left")
    flagged = flagged.sort_values(["vus", "tier", "rep"])
    out = pd.DataFrame({
        "Group": [f"{_tier(t)} @ VUS={v}" for t, v in zip(flagged["tier"], flagged["vus"])],
        "Rep": flagged["rep"].to_numpy(),
        "Deviation from median rep (%)": flagged["deviation_pct"].round(1).to_numpy(),
        "Modified z": flagged["modified_z"].round(1).to_numpy(),
        "Median shift (%)": flagged["median_shift_pct"].round(1).to_numpy(),
        "First tenth / rest": flagged["first_tenth_ratio"].round(2).to_numpy(),
        "Compute stall (ms)": flagged["stall_ms"].round(3).to_numpy(),
        "Compute stall, other reps (ms)": flagged["stall_ms_others"].round(3).to_numpy(),
        "Thread dispatch (ms)": flagged["dispatch_ms"].round(3).to_numpy(),
        "Thread dispatch, other reps (ms)": flagged["dispatch_ms_others"].round(3).to_numpy(),
    })
    for src, col in (("python_throttle_ms", "Python core throttle (ms)"), ("python_mhz", "Python clock (MHz)"),
                     ("temp_start_c", "Start temp (C)"), ("placement", "Placement")):
        if src in flagged:
            out[col] = flagged[src].to_numpy()
    return out


def placement_table(cells):
    """Per VUS level and crowding above the even split: the cells' median latency
    deviation, their compute stall and thread dispatch above their design cell's median,
    and a Mann-Whitney test, with cells as units, of each uneven group's deviations
    against the even placements' at the same level."""
    data = cells.dropna(subset=["crowding_above_even"])
    if data.empty:
        return pd.DataFrame()
    data = data.assign(
        extra_stall=data["stall_ms"] - data.groupby(["tier", "vus"])["stall_ms"].transform("median"),
        extra_dispatch=data["dispatch_ms"] - data.groupby(["tier", "vus"])["dispatch_ms"].transform("median"),
    )
    rows = []
    for vus, level in data.groupby("vus"):
        even = level.loc[level["crowding_above_even"] == 0, "deviation_pct"]
        for above, part in level.groupby("crowding_above_even"):
            row = {"Concurrency (VUS)": int(vus), "Crowding above even split": float(above),
                   "Example placement": part["placement"].mode().iloc[0], "Cells": len(part),
                   "Share of the level's cells (%)": round(100 * len(part) / len(level), 1),
                   "Median latency deviation (%)": round(float(part["deviation_pct"].median()), 1) + 0.0,
                   "Median extra compute stall (ms)": round(float(part["extra_stall"].median()), 3) + 0.0,
                   "Median extra thread dispatch (ms)": round(float(part["extra_dispatch"].median()), 3) + 0.0,
                   "Mann-Whitney p vs even": np.nan, "Rank-biserial r vs even": np.nan}
            if above > 0 and len(even) >= 2 and len(part) >= 2:
                u, p = mannwhitneyu(part["deviation_pct"], even, alternative="two-sided")
                row["Mann-Whitney p vs even"] = float(f"{p:.3g}")
                row["Rank-biserial r vs even"] = round(2 * u / (len(part) * len(even)) - 1, 3)
            rows.append(row)
    return pd.DataFrame(rows)


def placement_figure(cells):
    """Latency deviation by crowding above the even split at each VUS level where both
    even and uneven placements occurred. None when no level has both."""
    data = cells.dropna(subset=["crowding_above_even"])
    levels = [v for v, g in data.groupby("vus")
              if (g["crowding_above_even"] == 0).any() and (g["crowding_above_even"] > 0).any()]
    if not levels:
        return None
    fig, axes = plt.subplots(1, len(levels), figsize=(3.6 * len(levels), 3.6), dpi=300, squeeze=False, sharey=True)
    tiers = sorted(data["tier"].unique(), key=_tier_order)
    colors = dict(zip(tiers, ["#2b5c8f", "#c0392b", "#27ae60", "#8e44ad", "#e67e22", "#16a085"]))
    rng = np.random.default_rng(0)
    for ax, vus in zip(axes[0], levels):
        level = data[data["vus"] == vus]
        for tier in tiers:
            part = level[level["tier"] == tier]
            jitter = rng.uniform(-0.04, 0.04, len(part)) * max(1.0, float(level["crowding_above_even"].max()))
            ax.scatter(part["crowding_above_even"] + jitter, part["deviation_pct"], s=14,
                       color=colors[tier], label=_tier(tier), alpha=0.85)
        ax.axhline(0, color="#333333", linewidth=0.8)
        ax.set_title(f"VUS={vus}", fontsize=9)
        ax.set_xlabel("Crowding above even split")
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    axes[0][0].set_ylabel("Latency deviation from median rep (%)")
    axes[0][-1].legend(fontsize=6, loc="upper left")
    fig.suptitle("Scan cell latency by connection-to-worker placement", fontweight="bold", fontsize=10)
    fig.tight_layout()
    return fig


def _tier(tier):
    return f"v{tier}" if str(tier).isdigit() else str(tier)


def _tier_order(tier):
    order = ["calibration", "mock", "5", "10", "20", "28"]
    return order.index(tier) if tier in order else len(order)
