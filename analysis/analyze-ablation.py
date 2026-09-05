"""
Analyzes run-ablation.sh's output: isolates which of three candidate
mechanisms (AnyIO thread-limiter capacity, physical-core ceiling, GIL
contention via process count) drives Thread Dispatch time at VUS=64.

Each arm holds two mechanisms at a control value and sweeps the third;
values are read directly from ablation_run_metadata.json rather than
hardcoded here, so this script always reflects what run-ablation.sh
actually ran. Rep-level stats use the same cluster-bootstrap and
Mann-Whitney approach as analyze-results.py, applied to one pairwise
comparison per arm (control vs. its most extreme value) instead of the
full pairwise grid, since each arm here has an a priori ordered sweep.

Usage:
    python3 analyze-ablation.py [--results-dir ../results] [--output-dir ./output]
"""

import argparse
import glob
import json
import os

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
}
METRICS = {
    "python_thread_dispatch_time_ms": "Thread Dispatch",
    "python_model_inference_time_ms": "Model Inference",
    "python_total_time_ms": "Total",
}


def _value_sort_key(v):
    """Sorts '0-2'/'8-13'/'8-15' by core count, plain numbers numerically."""
    if "-" in v:
        lo, hi = v.split("-")
        return int(hi) - int(lo) + 1
    try:
        return int(v)
    except ValueError:
        return v


def load_ablation_cells(results_dir):
    """Loads ablation_<arm>_<value>_rep<N>.json files (excludes ablation_warmup_*)."""
    files = sorted(glob.glob(os.path.join(results_dir, "ablation_*.json")))
    files = [f for f in files if "warmup" not in os.path.basename(f)]
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
                if tags.get("phase") != "ablation" or tags.get("status") != "200":
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
    """Resamples whole reps with replacement; see analyze-results.py for rationale."""
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


def build_decomposition_table(df):
    rows = []
    for arm in sorted(df["arm"].unique()):
        arm_df = df[df["arm"] == arm]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        for value in values:
            cell = arm_df[arm_df["arm_value"] == value]
            row = {"Arm": ARM_LABELS.get(arm, arm), "Value": value,
                   "N (pooled)": int((cell["metric"] == "python_total_time_ms").sum())}
            for metric, label in METRICS.items():
                sub = cell[cell["metric"] == metric]
                if sub.empty:
                    row[f"{label} Mean (ms)"] = np.nan
                    continue
                lo, hi = cluster_bootstrap_ci(sub)
                row[f"{label} Mean (ms)"] = round(sub["value"].mean(), 3)
                row[f"{label} 95% CI"] = f"[{lo:.2f}, {hi:.2f}]"
            total_mean = row.get("Total Mean (ms)", np.nan)
            dispatch_mean = row.get("Thread Dispatch Mean (ms)", np.nan)
            row["Thread Dispatch % of Total"] = (
                round(100 * dispatch_mean / total_mean, 1) if total_mean else np.nan
            )
            rows.append(row)
    return pd.DataFrame(rows)


def control_vs_extreme_test(df, metric="python_thread_dispatch_time_ms"):
    """Rep-level Mann-Whitney, control value vs. the arm's most extreme value.
    One comparison per arm (not a grid), so no multiple-comparison correction
    is needed here -- unlike analyze-results.py's pairwise_mannwhitneyu."""
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
        rows.append({
            "Arm": ARM_LABELS.get(arm, arm),
            "Control": control, "Extreme": extreme,
            "Control Mean (ms)": round(control_means.mean(), 3),
            "Extreme Mean (ms)": round(extreme_means.mean(), 3),
            "Delta (ms)": round(extreme_means.mean() - control_means.mean(), 3),
            "N reps (control/extreme)": f"{len(control_means)}/{len(extreme_means)}",
            "p-value": round(p, 4),
        })
    return pd.DataFrame(rows)


def save_table(df, name, output_dir):
    if df is None or df.empty:
        print(f"[!] Skipping empty table: {name}")
        return
    tables_dir = os.path.join(output_dir, "tables")
    os.makedirs(tables_dir, exist_ok=True)
    df.to_csv(os.path.join(tables_dir, f"{name}.csv"), index=False)
    with open(os.path.join(tables_dir, f"{name}.md"), "w") as f:
        f.write(df.to_markdown(index=False))
    print(f"[+] Table  -> {tables_dir}/{name}.csv / .md")


def plot_ablation(df, output_dir):
    arms = sorted(df["arm"].unique())
    fig, axes = plt.subplots(1, len(arms), figsize=(5 * len(arms), 4), sharey=True)
    if len(arms) == 1:
        axes = [axes]

    for ax, arm in zip(axes, arms):
        arm_df = df[df["arm"] == arm]
        values = sorted(arm_df["arm_value"].unique(), key=_value_sort_key)
        dispatch_means, other_means = [], []
        for value in values:
            cell = arm_df[arm_df["arm_value"] == value]
            total = cell.loc[cell["metric"] == "python_total_time_ms", "value"].mean()
            dispatch = cell.loc[cell["metric"] == "python_thread_dispatch_time_ms", "value"].mean()
            dispatch_means.append(dispatch)
            other_means.append(max(total - dispatch, 0))

        x = np.arange(len(values))
        ax.bar(x, other_means, label="Rest of Total", color="#2b5c8f")
        ax.bar(x, dispatch_means, bottom=other_means, label="Thread Dispatch", color="#c0392b")
        ax.set_xticks(x)
        ax.set_xticklabels(values)
        ax.set_title(ARM_LABELS.get(arm, arm))
        ax.set_xlabel("Value")
    axes[0].set_ylabel("Mean Latency (ms)")
    axes[0].legend()
    fig.suptitle(f"Thread Dispatch vs. Candidate Mechanism (VUS=64)")
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
        print(f"[!] No ablation_*.json files found in {args.results_dir}. Run run-ablation.sh first.")
        return
    print(f"[*] Loaded {len(df)} metric points across {df['arm'].nunique()} arm(s).")

    save_table(build_decomposition_table(df), "table_ablation_decomposition", args.output_dir)
    save_table(control_vs_extreme_test(df), "table_ablation_control_vs_extreme", args.output_dir)
    plot_ablation(df, args.output_dir)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()