"""
Analyzes run-ablation.sh's output: isolates which of three candidate
mechanisms (AnyIO thread-limiter capacity, physical-core ceiling, GIL
contention via process count) drives Thread Dispatch time at VUS=64.

Each arm holds the other mechanisms at their control value and sweeps one.
Rep-level stats use the same cluster-bootstrap and Mann-Whitney approach
as analyze-results.py, applied to one pairwise comparison per arm
(control vs. its most extreme value) rather than a full pairwise grid,
since each arm has an a priori ordered sweep.

Usage:
    python3 analyze-ablation.py [--results-dir ../results] [--output-dir ./output]
"""

import argparse
import glob
import json
import os
import re

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

DEFAULT_RESULTS_DIR = os.path.join(os.path.dirname(__file__), "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "output")

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

# ablation_<arm>_<value>_rep<N>.json. Gating on a known arm also rejects
# ablation_warmup_* and ablation_run_metadata.json, which share the prefix.
CELL_FILE_RE = re.compile(r"^ablation_(?P<arm>[a-z_]+)_(?P<value>[^_]+)_rep(?P<rep>\d+)\.json$")

# The one configuration every arm holds as its control, so the cells that
# realize it can be cross-checked against each other.
CONTROL_CELL = {"thread_limiter": "40", "cpuset": "0-1,4-5,8-9", "workers": "3"}


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
    """Loads ablation_<arm>_<value>_rep<N>.json cell files."""
    files = [f for f in sorted(glob.glob(os.path.join(results_dir, "ablation_*.json")))
             if _is_cell_file(f)]
    if not files:
        return None

    rows = []
    for fp in files:
        with open(fp) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "Point" or obj.get("metric") not in METRICS:
                    continue
                tags = (obj.get("data", {}) or {}).get("tags", {}) or {}
                if tags.get("phase") != "ablation":
                    continue
                rows.append({
                    "metric": obj["metric"],
                    "value": pd.to_numeric(obj["data"].get("value"), errors="coerce"),
                    "arm": tags.get("arm"),
                    "arm_value": tags.get("arm_value"),
                    "rep": tags.get("rep", "1"),
                })
    if not rows:
        return None
    df = pd.DataFrame(rows)
    df = df.dropna(subset=["value", "arm", "arm_value"])
    return df


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


def build_decomposition_table(df):
    rows = []
    for arm in sorted(df["arm"].unique()):
        arm_df = df[df["arm"] == arm]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        for value in values:
            cell = arm_df[arm_df["arm_value"] == value]
            row = {"Arm": ARM_LABELS.get(arm, arm), "Value": value,
                   "N reps": int(cell["rep"].nunique()),
                   "N (pooled)": int((cell["metric"] == "python_total_time_ms").sum())}
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


def build_control_agreement_table(df, metric="python_thread_dispatch_time_ms"):
    """Compares the cells that realize the shared control configuration.

    Every arm holds the other mechanisms at CONTROL_CELL, so those cells are
    repeated measurements of one configuration. Disagreement between them is
    drift or an order effect rather than the manipulated factor.
    """
    rows = []
    for arm, value in CONTROL_CELL.items():
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


def control_vs_extreme_test(df, metric="python_thread_dispatch_time_ms"):
    """Rep-level Mann-Whitney, control value vs. the arm's most extreme value.
    One planned comparison per arm, so no multiple-comparison correction applies."""
    rows = []
    for arm in sorted(df["arm"].unique()):
        arm_df = df[(df["arm"] == arm) & (df["metric"] == metric)]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        if len(values) < 2:
            continue
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
            f.write(f"\\caption{{{caption}}}\n")
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


def main():
    parser = argparse.ArgumentParser(description="Analyze run-ablation.sh's thread-dispatch mechanism sweep.")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    args = parser.parse_args()

    failures_log = os.path.join(args.results_dir, "ablation_run_failures_log.txt")
    if os.path.isfile(failures_log) and os.path.getsize(failures_log) > 0:
        print(f"[!] {failures_log} has entries -- fix the cause and re-run run-ablation.sh.")
        return

    df = load_ablation_cells(args.results_dir)
    if df is None:
        print(f"[!] No ablation_*.json cell files found in {args.results_dir}. Run run-ablation.sh first.")
        return

    n_reps = df["rep"].nunique()
    print(f"[*] Loaded {len(df)} metric points across {df['arm'].nunique()} arm(s), {n_reps} rep(s).")

    # Both headline outputs are rep-level: the CIs resample whole reps and the
    # significance test ranks per-rep means. Saying so up front beats emitting a
    # table of NaN CIs and an empty test table with no explanation.
    if n_reps < 2:
        print(f"[!] Only {n_reps} rep detected. Bootstrap CIs cannot be computed and no "
              f"significance test can run. This output is a pipeline check, not a result.")
    elif n_reps < 4:
        print(f"[!] Only {n_reps} reps detected. No split of {n_reps} vs {n_reps} reaches "
              f"p<0.05 under a two-sided Mann-Whitney, so the control-vs-extreme test cannot "
              f"be significant regardless of effect size. Re-run with REPS_ABLATION_OVERRIDE>=7.")

    save_table(build_decomposition_table(df), "table_ablation_decomposition", args.output_dir,
               caption="Per-arm latency decomposition at VUS=64. Each arm holds the other "
                       "mechanisms at their control value and sweeps one. CIs are 95\\% cluster "
                       "bootstraps resampling whole repetitions, so they reflect between-run "
                       "variation rather than within-run request spread.",
               label="tab:ablation-decomposition")
    save_table(build_control_agreement_table(df), "table_ablation_control_agreement", args.output_dir,
               caption="Agreement between the cells that realize the shared control configuration. "
                       "Each arm holds the other two mechanisms at this configuration, so these "
                       "cells are repeated measurements of one setup; the spread between them "
                       "bounds how much of any arm's effect could be drift or order rather than "
                       "the manipulated factor.",
               label="tab:ablation-control-agreement")
    save_table(control_vs_extreme_test(df), "table_ablation_control_vs_extreme", args.output_dir,
               caption="Rep-level two-sided Mann-Whitney comparing each arm's control value to its "
                       "most extreme value, on mean thread-dispatch time. One planned comparison per "
                       "arm, so no multiple-comparison correction is applied. Rank-biserial effect "
                       "size reported alongside significance.",
               label="tab:ablation-significance")
    plot_ablation(df, args.output_dir)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()