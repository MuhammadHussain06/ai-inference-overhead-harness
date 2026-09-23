"""
Analyzes run-ablation.sh's output: isolates which of three candidate
mechanisms (AnyIO thread-limiter capacity, physical-core ceiling, GIL
contention via process count) drives Thread Dispatch time at VUS=64.

Each arm holds the other mechanisms at their control value and sweeps one.
Rep-level stats use the same cluster-bootstrap and Mann-Whitney approach
as analyze-results.py, applied to one planned comparison per arm (its
control value against the sweep value farthest from it) rather than a full
pairwise grid, since each arm has an a priori ordered sweep.

Usage:
    python3 analyze-ablation.py [--results-dir ../results] [--output-dir ./output]
"""

import argparse
import glob
import gzip
import json
import os
import random
import re
import sys

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

ANALYSIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ANALYSIS_DIR, "lib"))
import thermal  # noqa: E402
import warmup_check  # noqa: E402

DEFAULT_RESULTS_DIR = os.path.join(ANALYSIS_DIR, "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(ANALYSIS_DIR, "output")

ARM_LABELS = {
    "thread_limiter": "Thread-Limiter Tokens",
    "cpuset": "CPU Cores",
    "workers": "Uvicorn Workers",
    "workers_token_matched": "Uvicorn Workers (aggregate tokens held constant)",
}
METRICS = {
    "python_thread_dispatch_time_ms": "Thread Dispatch",
    "python_model_inference_time_ms": "Model Inference",
    "python_total_time_ms": "Total",
}

# ablation_<arm>_<value>_rep<N>.json[.gz]. The _rep<N> suffix already rejects
# ablation_run_metadata.json; gating on a known arm additionally rejects
# ablation_warmup_*, which otherwise parses with arm='warmup_<arm>'.
CELL_FILE_RE = re.compile(r"^ablation_(?P<arm>[a-z_]+)_(?P<value>[^_]+)_rep(?P<rep>\d+)\.json(\.gz)?$")

# ablation_warmup_<arm>_<value>_rep<N>.json[.gz]. The warm-up call itself carries no
# arm/arm_value tag (only the real cell that follows sets ARM/ARM_VALUE), so which
# cell a warm-up file belongs to comes from its filename, same as CELL_FILE_RE.
WARMUP_FILE_RE = re.compile(r"^ablation_warmup_(?P<arm>[a-z_]+)_(?P<value>[^_]+)_rep(?P<rep>\d+)\.json(\.gz)?$")

# The shared control configuration, keyed by the arm_value whose cell realizes it,
# so those cells can be cross-checked against each other. run-ablation.sh records
# the values it ran in ablation_run_metadata.json (control_cells() reads them);
# these are its defaults. workers_token_matched has no entry: its 3-worker cell
# rescales tokens to 13, so it is a different configuration.
CONTROL_CELL = {"thread_limiter": "40", "cpuset": "0-1,4-5,8-9", "workers": "3"}

# Same per-file cap as analyze-results.py's load_results(), sized identically so
# both loaders behave alike. Ablation cells sit at one model-inference tier and
# keep 3 metrics, so the cap is normally slack; it bounds memory if an arm/value
# combination ever raises throughput enough to reach it.
MAX_POINTS_PER_FILE = 250_000


def read_metadata(results_dir):
    """ablation_run_metadata.json, or {} when absent or unreadable."""
    path = os.path.join(results_dir, "ablation_run_metadata.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"[!] ablation_run_metadata.json could not be read ({e}); using defaults.")
        return {}


def control_cells(metadata):
    """The control value each arm ran with, as recorded by run-ablation.sh."""
    recorded = (metadata or {}).get("ablation_config", {}).get("control_values", {})
    return {arm: str(recorded.get(arm, default)) for arm, default in CONTROL_CELL.items()}


def _cpu_count_of(cpuset):
    """Counts logical CPUs in a cpuset string ('0-1', '0-1,4-5,8-9')."""
    total = 0
    for part in cpuset.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            total += int(hi) - int(lo) + 1
        else:
            total += 1
    return total


def _value_sort_key(v):
    """Sorts cpuset strings by logical-CPU count and plain numbers numerically.
    run-ablation.sh emits multi-range cpusets, so single-range parsing is not enough."""
    if "-" in v or "," in v:
        try:
            return _cpu_count_of(v)
        except ValueError:
            return v
    try:
        return int(v)
    except ValueError:
        return v


def _is_cell_file(path):
    m = CELL_FILE_RE.match(os.path.basename(path))
    return m is not None and m.group("arm") in ARM_LABELS


def load_ablation_cells(results_dir):
    """Loads ablation_<arm>_<value>_rep<N>.json[.gz] cell files.

    Returns (df, counts): df holds the METRICS points (reservoir-sampled per file);
    counts holds each cell's full request outcome tally, counted before sampling --
    HTTP 200s, other responses, requests with no response, and dropped iterations.
    Both are None when no cell file exists."""
    files = [f for f in sorted(
                glob.glob(os.path.join(results_dir, "ablation_*.json"))
                + glob.glob(os.path.join(results_dir, "ablation_*.json.gz"))
             ) if _is_cell_file(f)]
    if not files:
        return None, None

    # json.loads() doesn't intern strings, so each tag repeats as a new object
    # per row instead of one shared object per distinct value.
    def _intern_tag(v):
        return sys.intern(v) if type(v) is str else v

    rng = random.Random(42)
    rows, count_rows = [], []
    for fp in files:
        m = CELL_FILE_RE.match(os.path.basename(fp))
        tally = {"arm": m.group("arm"), "arm_value": m.group("value"), "rep": m.group("rep"),
                 "ok": 0, "http_error": 0, "no_response": 0, "dropped": 0}
        file_rows = []
        n_seen = 0
        lines_read = 0
        opener = gzip.open if fp.endswith(".gz") else open
        with opener(fp, "rt") as f:
            try:
                for line in f:
                    lines_read += 1
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") != "Point":
                        continue
                    metric = obj.get("metric")
                    data = obj.get("data", {}) or {}
                    tags = data.get("tags", {}) or {}
                    if metric == "dropped_iterations":
                        # An engine metric: it carries no phase tag, and the file is the cell.
                        tally["dropped"] += int(data.get("value") or 0)
                        continue
                    if tags.get("phase") != "ablation":
                        continue
                    if metric == "http_req_duration":
                        status = tags.get("status")
                        key = ("ok" if status == "200"
                               else "no_response" if status in (None, "0") else "http_error")
                        tally[key] += 1
                        continue
                    if metric not in METRICS:
                        continue
                    row = {
                        "metric": _intern_tag(metric),
                        "value": pd.to_numeric(data.get("value"), errors="coerce"),
                        "arm": _intern_tag(tags.get("arm")),
                        "arm_value": _intern_tag(tags.get("arm_value")),
                        "rep": _intern_tag(tags.get("rep", "1")),
                    }
                    # Algorithm R: the first MAX_POINTS_PER_FILE rows are always kept; each
                    # later row replaces a uniformly random slot with probability
                    # MAX_POINTS_PER_FILE/n_seen, leaving every row seen equally likely to
                    # survive. The outcome tally above is counted before this, so it is exact.
                    n_seen += 1
                    if n_seen <= MAX_POINTS_PER_FILE:
                        file_rows.append(row)
                    else:
                        idx = rng.randint(0, n_seen - 1)
                        if idx < MAX_POINTS_PER_FILE:
                            file_rows[idx] = row
            except (EOFError, OSError) as e:
                # Raised by the decompressor, not json.loads: what decompressed
                # cleanly is kept rather than losing the whole run.
                print(f"[!] {os.path.basename(fp)}: compressed stream ended early after "
                      f"{lines_read} line(s) ({e}). Using what decompressed cleanly.")
        if n_seen > MAX_POINTS_PER_FILE:
            print(f"[!] {os.path.basename(fp)}: {n_seen} points subsampled to "
                  f"{MAX_POINTS_PER_FILE} (uniform random sample) to bound memory.")
        rows.extend(file_rows)
        count_rows.append(tally)
    counts = pd.DataFrame(count_rows)
    if not rows:
        return None, counts
    df = pd.DataFrame(rows)
    df = df.dropna(subset=["value", "arm", "arm_value"])
    # float32 halves this column's memory versus float64; ablation latencies
    # don't need more precision than that.
    df["value"] = df["value"].astype(np.float32)
    return df, counts


def cluster_bootstrap_ci(sub_df, n_boot=2000, ci=0.95, seed=42):
    """Resamples whole reps with replacement to avoid pseudoreplication; same approach as analyze-results.py."""
    reps = sub_df["rep"].unique()
    if len(reps) < 2:
        return (np.nan, np.nan)
    rep_values = {r: sub_df.loc[sub_df["rep"] == r, "value"].to_numpy() for r in reps}
    rng = np.random.default_rng(seed)
    boot_means = np.empty(n_boot)
    for i in range(n_boot):
        chosen = rng.choice(reps, size=len(reps), replace=True)
        boot_means[i] = np.concatenate([rep_values[r] for r in chosen]).mean()
    alpha = (1 - ci) / 2
    lo, hi = np.quantile(boot_means, [alpha, 1 - alpha])
    return (float(lo), float(hi))


def rank_biserial_effect_size(U, n1, n2):
    """Rank-biserial correlation from a Mann-Whitney U statistic, on Cliff's delta's own
    sign convention: delta = P(A > B) - P(A < B), from the U scipy returns for the FIRST
    sample. Ranges [-1, 1]; 0 = no separation. NEGATIVE means A's values are smaller than
    B's. Must stay identical to analyze-results.py's copy (asserted by the test suite)."""
    return (2 * U) / (n1 * n2) - 1


def _effect_magnitude(delta):
    """Romano et al. (2006) thresholds for Cliff's delta."""
    d = abs(delta)
    if d < 0.147:
        return "negligible"
    elif d < 0.33:
        return "small"
    elif d < 0.474:
        return "medium"
    return "large"


def build_decomposition_table(df, counts=None):
    """counts: load_ablation_cells()'s outcome tally, for an N that sampling did not reduce."""
    rows = []
    for arm in sorted(df["arm"].unique()):
        arm_df = df[df["arm"] == arm]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        for value in values:
            cell = arm_df[arm_df["arm_value"] == value]
            n_ok = (int(counts.loc[(counts["arm"] == arm) & (counts["arm_value"] == value), "ok"].sum())
                    if counts is not None and not counts.empty else 0)
            row = {"Arm": ARM_LABELS.get(arm, arm), "Value": value,
                   "N reps": int(cell["rep"].nunique()),
                   "N requests (HTTP 200, pooled)": n_ok or int((cell["metric"] == "python_total_time_ms").sum())}
            for metric, label in METRICS.items():
                sub = cell[cell["metric"] == metric]
                if sub.empty:
                    row[f"{label} Mean (ms)"] = np.nan
                    continue
                lo, hi = cluster_bootstrap_ci(sub)
                row[f"{label} Mean (ms)"] = round(sub["value"].mean(), 3)
                # A single rep gives the bootstrap nothing to resample over.
                row[f"{label} 95% CI"] = (
                    "n/a (needs >=2 reps)" if np.isnan(lo) else f"[{lo:.2f}, {hi:.2f}]"
                )
            total_mean = row.get("Total Mean (ms)", np.nan)
            dispatch_mean = row.get("Thread Dispatch Mean (ms)", np.nan)
            row["Thread Dispatch % of Total"] = (
                round(100 * dispatch_mean / total_mean, 1)
                if total_mean and not np.isnan(total_mean) and not np.isnan(dispatch_mean) else np.nan
            )
            rows.append(row)
    return pd.DataFrame(rows)


def build_control_agreement_table(df, metric="python_thread_dispatch_time_ms", controls=None):
    """Compares the cells that realize the shared control configuration.

    The arms named in CONTROL_CELL each hold the other mechanisms at that
    configuration, so those cells are repeated measurements of one setup.
    Disagreement between them is drift or an order effect rather than the
    manipulated factor.
    """
    rows = []
    for arm, value in (controls or CONTROL_CELL).items():
        cell = df[(df["arm"] == arm) & (df["arm_value"] == value) & (df["metric"] == metric)]
        if cell.empty:
            continue
        rep_means = cell.groupby("rep")["value"].mean()
        rows.append({
            "Arm holding this as control": ARM_LABELS.get(arm, arm),
            "Value": value,
            "N reps": len(rep_means),
            "Mean Thread Dispatch (ms)": round(float(rep_means.mean()), 3),
            "SD across reps (ms)": round(float(rep_means.std(ddof=1)), 3) if len(rep_means) > 1 else 0.0,
        })
    table = pd.DataFrame(rows)
    if len(table) > 1:
        means = table["Mean Thread Dispatch (ms)"]
        spread = 100 * (means.max() - means.min()) / means.mean() if means.mean() else np.nan
        table["Spread across control cells (%)"] = round(spread, 1)
    return table


def _extreme_value(values, control):
    """The sweep value farthest from control: by numeric distance on _value_sort_key
    (logical CPUs for a cpuset), falling back to sweep position for values without a
    numeric key. A tie goes to the value later in sweep order."""
    keys = [_value_sort_key(v) for v in values]
    c = _value_sort_key(control)
    if all(isinstance(k, (int, float)) for k in keys + [c]):
        distance = [abs(k - c) for k in keys]
    else:
        idx = values.index(control)
        distance = [abs(i - idx) for i in range(len(values))]
    best = max(distance)
    return [v for v, d in zip(values, distance) if d == best][-1]


def control_vs_extreme_test(df, metric="python_thread_dispatch_time_ms", controls=None):
    """Rep-level Mann-Whitney between each arm's control value and the sweep value
    farthest from it (_extreme_value), so the comparison is the arm's largest
    manipulation whether the control sits at an end of the sweep (thread_limiter,
    workers) or inside it (cpuset). workers_token_matched has no control entry: its
    two values are a matched pair at fixed token capacity, compared directly.
    One planned comparison per arm, so no multiple-comparison correction applies."""
    controls = controls or CONTROL_CELL
    rows = []
    for arm in sorted(df["arm"].unique()):
        arm_df = df[(df["arm"] == arm) & (df["metric"] == metric)]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        if len(values) < 2:
            continue
        control_value = controls.get(arm)
        if control_value is not None and control_value in values:
            control = control_value
            extreme = _extreme_value(values, control)
        else:
            control, extreme = values[0], values[-1]
        control_means = arm_df[arm_df["arm_value"] == control].groupby("rep")["value"].mean()
        extreme_means = arm_df[arm_df["arm_value"] == extreme].groupby("rep")["value"].mean()
        if len(control_means) < 2 or len(extreme_means) < 2:
            continue
        u_stat, p = mannwhitneyu(control_means, extreme_means, alternative="two-sided")
        effect = rank_biserial_effect_size(u_stat, len(control_means), len(extreme_means))
        rows.append({
            "Arm": ARM_LABELS.get(arm, arm),
            "Control": control, "Extreme": extreme,
            "Control Mean (ms)": round(control_means.mean(), 3),
            "Extreme Mean (ms)": round(extreme_means.mean(), 3),
            "Delta (ms)": round(extreme_means.mean() - control_means.mean(), 3),
            "N reps (control/extreme)": f"{len(control_means)}/{len(extreme_means)}",
            "U statistic": round(float(u_stat), 1),
            "p-value": round(p, 4),
            "Effect size (rank-biserial r)": round(float(effect), 3),
            "Effect magnitude": _effect_magnitude(effect),
        })
    return pd.DataFrame(rows)


def build_error_table(counts):
    """Per (arm, value): every request's outcome and the iterations k6 dropped, from
    the exact tally. Latency tables cover HTTP 200 requests only, so a cell that
    shed load through errors or dropped iterations reads faster than it ran."""
    if counts is None or counts.empty:
        return pd.DataFrame()
    rows = []
    for arm in sorted(counts["arm"].unique()):
        arm_counts = counts[counts["arm"] == arm]
        for value in sorted(arm_counts["arm_value"].unique(), key=_value_sort_key):
            g = arm_counts[arm_counts["arm_value"] == value]
            total = int(g[["ok", "http_error", "no_response"]].to_numpy().sum())
            rows.append({
                "Arm": ARM_LABELS.get(arm, arm), "Value": value, "N reps": len(g),
                "Total Requests": total,
                "Successful (200)": int(g["ok"].sum()),
                "HTTP Errors (non-200 response)": int(g["http_error"].sum()),
                "Timeouts / Network Errors (no response)": int(g["no_response"].sum()),
                "Error Rate (%)": round(100 * (1 - g["ok"].sum() / total), 2) if total else np.nan,
                "Dropped iterations": int(g["dropped"].sum()),
            })
    return pd.DataFrame(rows)


def _latex_text(text):
    """Escapes the LaTeX specials a caption can contain, leaving already-escaped ones."""
    return re.sub(r"(?<!\\)([%_&#])", r"\\\1", text)


def save_table(df, name, output_dir, caption=None, label=None):
    """Emits csv/md/tex, matching analyze-results.py so both sets drop into the same paper."""
    if df is None or df.empty:
        print(f"[!] Skipping empty table: {name}")
        return
    tables_dir = os.path.join(output_dir, "tables")
    os.makedirs(tables_dir, exist_ok=True)
    df.to_csv(os.path.join(tables_dir, f"{name}.csv"), index=False)
    with open(os.path.join(tables_dir, f"{name}.md"), "w") as f:
        f.write(df.to_markdown(index=False))
    with open(os.path.join(tables_dir, f"{name}.tex"), "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n")
        # Caption precedes the tabular body so it renders above the table,
        # matching Elsevier/JSS style.
        if caption:
            f.write(f"\\caption{{{_latex_text(caption)}}}\n")
        if label:
            f.write(f"\\label{{{label}}}\n")
        f.write(df.to_latex(index=False, escape=True))
        f.write("\\end{table}\n")
    print(f"[+] Table  -> {tables_dir}/{name}.csv / .md / .tex")


def plot_ablation(df, output_dir):
    arms = sorted(df["arm"].unique())
    fig, axes = plt.subplots(1, len(arms), figsize=(5 * len(arms), 4), sharey=True)
    if len(arms) == 1:
        axes = [axes]

    for ax, arm in zip(axes, arms):
        arm_df = df[df["arm"] == arm]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        dispatch_means, other_means, dispatch_errs = [], [], []
        for value in values:
            cell = arm_df[arm_df["arm_value"] == value]
            dispatch_points = cell[cell["metric"] == "python_thread_dispatch_time_ms"]
            total = cell.loc[cell["metric"] == "python_total_time_ms", "value"].mean()
            dispatch = dispatch_points["value"].mean()
            dispatch_means.append(dispatch)
            # Defined as a residual so the two segments sum to the measured total.
            other_means.append(max(total - dispatch, 0))
            # SD of per-rep means: between-run spread of the compared segment.
            rep_means = dispatch_points.groupby("rep")["value"].mean()
            dispatch_errs.append(float(rep_means.std(ddof=1)) if len(rep_means) > 1 else 0.0)

        x = np.arange(len(values))
        tick_labels = [f"{v}\n({_cpu_count_of(v)} CPUs)" if ("-" in v or "," in v) else v
                       for v in values]
        ax.bar(x, other_means, label="Rest of Total", color="#2b5c8f")
        ax.bar(x, dispatch_means, bottom=other_means, label="Thread Dispatch", color="#c0392b",
               yerr=dispatch_errs, capsize=4, ecolor="#333333")
        ax.set_xticks(x)
        ax.set_xticklabels(tick_labels, fontsize=8)
        ax.set_title(ARM_LABELS.get(arm, arm), fontsize=9)
        ax.set_xlabel("Value")
    axes[0].set_ylabel("Mean Latency (ms)")
    axes[0].legend()
    n_reps = df["rep"].nunique()
    fig.suptitle(f"Thread Dispatch vs. Candidate Mechanism "
                 f"(VUS=64, N={n_reps} runs, error bars = SD of thread dispatch across runs)")
    fig.tight_layout()

    figures_dir = os.path.join(output_dir, "figures")
    os.makedirs(figures_dir, exist_ok=True)
    fig.savefig(os.path.join(figures_dir, "figure_ablation_mechanisms.png"), dpi=300, bbox_inches="tight")
    fig.savefig(os.path.join(figures_dir, "figure_ablation_mechanisms.pdf"), bbox_inches="tight")
    plt.close(fig)
    print(f"[+] Figure -> {figures_dir}/figure_ablation_mechanisms.png / .pdf")


def build_ablation_warmup_table(results_dir, metadata=None):
    """Per-cell warm-up convergence, judged by the live gate (lib/warmup_gate.py) at
    the parameters run-ablation.sh recorded. Reads ablation_warmup_* files, which
    load_ablation_cells() never touches. Returns (table, gate parameters)."""
    config = (metadata or {}).get("ablation_config", {})
    params = warmup_check.gate_params(config.get("warmup_gate"))
    expect = [str(config["target"])] if config.get("target") else []
    entries = []
    for fp in glob.glob(os.path.join(results_dir, "ablation_warmup_*.json*")):
        m = WARMUP_FILE_RE.match(os.path.basename(fp))
        if m:
            key = _value_sort_key(m.group("value"))
            order = (0, key, "") if isinstance(key, int) else (1, 0, str(key))
            entries.append((m.group("arm"), order, int(m.group("rep")), m, fp))
    rows = []
    for arm, _, _, m, fp in sorted(entries, key=lambda e: e[:3]):
        file_rows, truncated = warmup_check.file_rows(fp, expect, params, str)
        if truncated:
            print(f"[!] {os.path.basename(fp)}: compressed stream ended early; judged on what "
                  f"decompressed cleanly.")
        rows.extend({"Arm": ARM_LABELS.get(arm, arm), "Value": m.group("value"), "Rep": m.group("rep"), **r}
                    for r in file_rows)
    return pd.DataFrame(rows), params


# thermal state per cell

def _ablation_phase(name):
    """Run phase of a trace line's name: an env-sample label, a cell or a thermal-check label."""
    name = str(name or "")
    if name.startswith(("ablation_calib_warmup", "calibration")):
        return "calibration pass"
    if name.startswith("ablation_warmup_"):
        return "warm-up"
    if name.startswith(("arm=", "ablation_")) or re.search(r"_rep\d+_(start|end)$", name):
        return "measured cells"
    return "other"


def _cell_key(cell):
    m = CELL_FILE_RE.match(f"{cell}.json")
    return (m.group("arm"), m.group("value")) if m else None


def analyze_thermal(results_dir, output_dir, metadata, df):
    """Temperature and throttling per ablation cell, the time thermal pauses cost,
    and whether either tracks a cell's thread-dispatch time."""
    path = os.path.join(results_dir, "ablation_env_trace_log.txt")
    if not os.path.isfile(path):
        print("[thermal] No ablation_env_trace_log.txt found -- skipping thermal analysis.")
        return
    trace = thermal.parse_env_trace(path)
    cores = (metadata or {}).get("cores_used_by_suite", {})
    controls = control_cells(metadata)
    fixed = {svc: cores.get(key) for svc, key in (("java", "transaction_service_cpuset"), ("k6", "k6_cpuset"))
             if cores.get(key) not in (None, "", "unknown")}

    def cpusets(cell):
        key = _cell_key(cell)
        python = key[1] if key and key[0] == "cpuset" else controls["cpuset"]
        return {"python": python, **fixed}

    cells = thermal.cell_thermal(trace, cpusets)
    if cells.empty:
        print("[thermal] ablation_env_trace_log.txt has no per-cell samples -- skipping thermal analysis.")
        return

    def order(key):
        value = _value_sort_key(key[1])
        return (key[0], (0, value, "") if isinstance(value, int) else (1, 0, str(value)))

    save_table(thermal.thermal_by_group(cells, _cell_key, ["python", *fixed],
                                        label_of=lambda key: f"{ARM_LABELS.get(key[0], key[0])} = {key[1]}",
                                        sort_key=order),
               "table_ablation_thermal_by_cell", output_dir,
               caption="Highest thermal-zone temperature at the start and end of each measured ablation "
                       "cell, and the thermal throttling accrued during it (Intel therm_throt counters, "
                       "differenced across the cell), per arm value. python's core throttle is read on "
                       "the cpuset that cell ran python-service on.",
               label="tab:ablation-thermal")
    save_table(thermal.thermal_pauses(trace, _ablation_phase), "table_ablation_thermal_pauses", output_dir,
               caption="Thermal safety checks per phase of the ablation run: how many paused it to let "
                       "the host cool, and the wall-clock time those pauses cost.",
               label="tab:ablation-thermal-pauses")

    dispatch = df[df["metric"] == "python_thread_dispatch_time_ms"]
    latency = (dispatch.groupby(["arm", "arm_value", "rep"], observed=True)["value"].mean()
               .reset_index(name="mean_ms"))
    latency["cell"] = "ablation_" + latency["arm"] + "_" + latency["arm_value"] + "_rep" + latency["rep"].astype(str)
    latency["group"] = latency["arm"] + ":" + latency["arm_value"]
    save_table(thermal.thermal_latency_association(cells, latency[["cell", "group", "mean_ms"]]),
               "table_ablation_thermal_association", output_dir,
               caption="Spearman correlation between a cell's thermal state and its mean thread-dispatch "
                       "time, taken as its percent deviation from the same arm value's mean across "
                       "repetitions, so the manipulated factor does not register as a thermal effect.",
               label="tab:ablation-thermal-association")

    fig = thermal.timeline_figure(trace, _ablation_phase, "Host temperature across the ablation run")
    if fig is not None:
        figures_dir = os.path.join(output_dir, "figures")
        os.makedirs(figures_dir, exist_ok=True)
        fig.savefig(os.path.join(figures_dir, "figure_ablation_thermal_timeline.png"), dpi=300, bbox_inches="tight")
        fig.savefig(os.path.join(figures_dir, "figure_ablation_thermal_timeline.pdf"), bbox_inches="tight")
        plt.close(fig)
        print(f"[+] Figure -> {figures_dir}/figure_ablation_thermal_timeline.png / .pdf")


def main():
    parser = argparse.ArgumentParser(description="Analyze run-ablation.sh's thread-dispatch mechanism sweep.")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    args = parser.parse_args()

    failures_log = os.path.join(args.results_dir, "ablation_run_failures_log.txt")
    if os.path.isfile(failures_log) and os.path.getsize(failures_log) > 0:
        print(f"[!] {failures_log} has entries -- fix the cause and re-run run-ablation.sh.")
        sys.exit(1)

    metadata = read_metadata(args.results_dir)
    controls = control_cells(metadata)

    warmup_table, params = build_ablation_warmup_table(args.results_dir, metadata)
    save_table(warmup_table, "table0_ablation_warmup_convergence_check", args.output_dir,
               caption=warmup_check.caption(params, "Per-cell"),
               label="tab:ablation-warmup-convergence")
    warmup_check.report(warmup_table, params, "ablation warm-up(s)", ["Arm", "Value", "Rep"])

    df, counts = load_ablation_cells(args.results_dir)
    # An all-dropped frame reaches plot_ablation() as zero arms, which plt.subplots()
    # rejects; stop here so a file set with no usable points reports rather than raises.
    if df is None or df.empty:
        print(f"[!] No usable ablation_*.json cell points found in {args.results_dir}. "
              f"Run run-ablation.sh first.")
        sys.exit(1)

    n_reps = df["rep"].nunique()
    print(f"[*] Loaded {len(df)} metric points across {df['arm'].nunique()} arm(s), {n_reps} rep(s).")

    # Both headline outputs are rep-level: the CIs resample whole reps and the
    # significance test ranks per-rep means, so too few reps yields NaN CIs and an
    # empty test table rather than an error.
    if n_reps < 2:
        print(f"[!] Only {n_reps} rep detected. Bootstrap CIs cannot be computed and no "
              f"significance test can run. This output is a pipeline check, not a result.")
    elif n_reps < 4:
        print(f"[!] Only {n_reps} reps detected. No split of {n_reps} vs {n_reps} reaches "
              f"p<0.05 under a two-sided Mann-Whitney, so the control-vs-extreme test cannot "
              f"be significant regardless of effect size. Re-run with REPS_ABLATION_OVERRIDE>=7.")

    errors = build_error_table(counts)
    save_table(errors, "table_ablation_error_rates", args.output_dir,
               caption="Request outcomes per arm value, pooled across repetitions and counted before "
                       "any sampling, with the iterations k6 dropped. The latency tables cover HTTP 200 "
                       "requests only, so a value with errors or dropped iterations ran fewer requests "
                       "than the others and reads faster than it served.",
               label="tab:ablation-error-rates")
    if not errors.empty and (errors["Error Rate (%)"].fillna(0).gt(0).any()
                             or errors["Dropped iterations"].gt(0).any()):
        print("[!] Some ablation cells had failed requests or dropped iterations -- see "
              "table_ablation_error_rates before comparing their latency.")

    save_table(build_decomposition_table(df, counts), "table_ablation_decomposition", args.output_dir,
               caption="Per-arm latency decomposition at VUS=64. Each arm holds the other "
                       "mechanisms at their control value and sweeps one. CIs are 95\\% cluster "
                       "bootstraps resampling whole repetitions, so they reflect between-run "
                       "variation rather than within-run request spread.",
               label="tab:ablation-decomposition")
    save_table(build_control_agreement_table(df, controls=controls), "table_ablation_control_agreement",
               args.output_dir,
               caption="Agreement between the cells that realize the shared control configuration. "
                       "Each arm holds the other two mechanisms at this configuration, so these "
                       "cells are repeated measurements of one setup; the spread between them "
                       "bounds how much of any arm's effect could be drift or order rather than "
                       "the manipulated factor.",
               label="tab:ablation-control-agreement")
    save_table(control_vs_extreme_test(df, controls=controls), "table_ablation_control_vs_extreme",
               args.output_dir,
               caption="Rep-level two-sided Mann-Whitney comparing each arm's control value to the "
                       "sweep value farthest from it, on mean thread-dispatch time. One planned "
                       "comparison per arm, so no multiple-comparison correction is applied. "
                       "Rank-biserial effect size reported alongside significance.",
               label="tab:ablation-significance")
    plot_ablation(df, args.output_dir)
    analyze_thermal(args.results_dir, args.output_dir, metadata, df)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()
