"""
Analyze k6 load-testing results from load-testing/run-suite.sh.

Evaluates latency distributions, scaling performance, and reproducibility across
baseline (E1) and concurrency scan (E2) experiments. Separates within-run request
noise (bootstrapped CIs) from between-run session variance (CoV% across clean stack
restarts), and performs non-parametric Mann-Whitney U tests between adjacent
tier/concurrency steps.

Usage:
    python3 analyze-results.py [--results-dir ../results] [--output-dir ./output]
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

TIER_ORDER = ["mock", "5", "10", "20", "28"]
CONCURRENCY_ORDER = [1, 2, 4, 8, 16, 32, 64]

PYTHON_TELEMETRY_METRICS = [
    "python_parsing_time_ms",
    "python_computation_time_ms",
    "python_dataframe_construction_time_ms",
    "python_model_inference_time_ms",
    "python_serialization_time_ms",
    "python_total_time_ms",
]

COLOR_CYCLE = ['#2b5c8f', '#c0392b', '#27ae60', '#8e44ad', '#e67e22', '#16a085']


def _tier_label(tier):
    return "mock" if tier in (None, "", "mock") else f"v{tier}"


def _rep_sort_key(r):
    try:
        return (0, int(r))
    except (TypeError, ValueError):
        return (1, str(r))


# Loading

def load_results(results_dir):

    files = sorted(glob.glob(os.path.join(results_dir, "*.json")))
    if not files:
        raise FileNotFoundError(
            f"No result files found in {results_dir}. Run load-testing/run-suite.sh first."
        )

    records = []
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
                if obj.get("type") != "Point":
                    continue
                data = obj.get("data", {}) or {}
                tags = data.get("tags", {}) or {}
                records.append({
                    "metric": obj.get("metric"),
                    "value": data.get("value"),
                    "strategy": tags.get("strategy"),
                    "tier": tags.get("tier"),
                    "vus": tags.get("vus"),
                    "phase": tags.get("phase"),
                    "rep": tags.get("rep"),
                    "time": data.get("time"),
                    "source_file": os.path.basename(fp),
                })

    if not records:
        raise ValueError(f"No 'Point' metric records found across {len(files)} file(s) in {results_dir}.")

    df = pd.DataFrame.from_records(records)
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    df["vus"] = pd.to_numeric(df["vus"], errors="coerce")
    df["time"] = pd.to_datetime(df["time"], errors="coerce", utc=True)
    df["rep"] = df["rep"].fillna("1")
    return df

# Stats — within-run

def bootstrap_ci(values, stat_fn, n_boot=2000, ci=0.95, seed=42):

    values = np.asarray(values, dtype=float)
    n = len(values)
    if n < 2:
        return (np.nan, np.nan)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, n, size=(n_boot, n))
    samples = values[idx]
    boot_stats = stat_fn(samples, axis=1)
    alpha = (1 - ci) / 2
    lo, hi = np.quantile(boot_stats, [alpha, 1 - alpha])
    return (float(lo), float(hi))


def summarize(values, label, n_boot=2000):

    values = pd.to_numeric(pd.Series(values), errors="coerce").dropna().to_numpy()
    n = len(values)
    if n == 0:
        return None

    mean_lo, mean_hi = bootstrap_ci(values, lambda s, axis: np.mean(s, axis=axis), n_boot=n_boot)
    p95_lo, p95_hi = bootstrap_ci(values, lambda s, axis: np.percentile(s, 95, axis=axis), n_boot=n_boot)

    return {
        "Group": label,
        "N (pooled, all reps)": n,
        "Mean (ms)": round(float(values.mean()), 3),
        "Mean 95% CI": f"[{mean_lo:.2f}, {mean_hi:.2f}]",
        "Median (ms)": round(float(np.percentile(values, 50)), 3),
        "P95 (ms)": round(float(np.percentile(values, 95)), 3),
        "P95 95% CI": f"[{p95_lo:.2f}, {p95_hi:.2f}]",
        "P99 (ms)": round(float(np.percentile(values, 99)), 3),
        "StdDev (ms)": round(float(values.std(ddof=1)) if n > 1 else 0.0, 3),
        "Min (ms)": round(float(values.min()), 3),
        "Max (ms)": round(float(values.max()), 3),
    }


def _throughput_reqs_per_s(subset_df):

    times = subset_df["time"].dropna()
    if len(times) < 2:
        return np.nan
    span_s = (times.max() - times.min()).total_seconds()
    if span_s <= 0:
        return np.nan
    return len(times) / span_s


# Stats — significance

def pairwise_mannwhitney(df, metric, phase, group_col, order, label_fn, fixed_filters=None):
    """
  Mann-Whitney U test between adjacent pairs in `order` using pooled request values.

  Evaluates if step-wise tier/concurrency increases significantly impact latency.
  Uses non-parametric Mann-Whitney U due to right-skewed latency distributions.
  Pools requests across repetitions for statistical power (noting within-rep correlation
  as a known limitation, complemented by between-run CoV% analysis).

  fixed_filters: Dict of column constraints (e.g., {"vus": 64}) applied during comparison.
  """
    sub = df[(df["metric"] == metric) & (df["phase"] == phase) & df["value"].notna()]
    if fixed_filters:
        for col, val in fixed_filters.items():
            sub = sub[sub[col] == val]

    rows = []
    for a, b in zip(order, order[1:]):
        vals_a = sub[sub[group_col] == a]["value"].to_numpy()
        vals_b = sub[sub[group_col] == b]["value"].to_numpy()
        if len(vals_a) < 2 or len(vals_b) < 2:
            continue
        stat, p = mannwhitneyu(vals_a, vals_b, alternative="two-sided")
        rows.append({
            "Comparison": f"{label_fn(a)} vs {label_fn(b)}",
            "N (A)": len(vals_a),
            "N (B)": len(vals_b),
            "Median A (ms)": round(float(np.median(vals_a)), 3),
            "Median B (ms)": round(float(np.median(vals_b)), 3),
            "U statistic": round(float(stat), 1),
            "p-value": f"{p:.2e}" if p < 0.001 else round(float(p), 4),
            "Significant (p<0.05)": "Yes" if p < 0.05 else "No",
        })
    return pd.DataFrame(rows)


# Stats — between-run

def between_run_consistency(df, metric, phase, group_cols, label_fn):
    """
    Compute between-run metrics (Mean, SD, CoV%) across independent repetitions.

    Aggregates per-repetition means to measure true session-to-session reproducibility,
    avoiding pooled statistics that mask run-level shifts. Uses direct summary statistics
    (Mean, SD, CoV%) to accommodate small repetition sample sizes (3–5 reps).
    """

    sub = df[(df["metric"] == metric) & (df["phase"] == phase) & df["value"].notna()].copy()
    if sub.empty:
        return pd.DataFrame()

    per_rep_mean = sub.groupby(group_cols + ["rep"])["value"].mean().reset_index()
    pivot = per_rep_mean.pivot_table(index=group_cols, columns="rep", values="value")
    rep_cols_sorted = sorted(pivot.columns, key=_rep_sort_key)
    pivot = pivot[rep_cols_sorted]

    row_mean = pivot.mean(axis=1)
    row_std = pivot.std(axis=1, ddof=1)
    row_count = pivot.count(axis=1)
    row_cov = 100 * row_std / row_mean

    pivot = pivot.rename(columns=lambda r: f"Rep {r} Mean (ms)").round(3)
    pivot["Mean of Reps (ms)"] = row_mean.round(3)
    pivot["StdDev Across Reps (ms)"] = row_std.fillna(0.0).round(3)
    pivot["Independent Runs"] = row_count.astype(int)
    pivot["CoV Across Reps (%)"] = row_cov.round(2)

    pivot = pivot.reset_index()
    pivot.insert(0, "Group", pivot[group_cols].apply(lambda row: label_fn(tuple(row)), axis=1))
    pivot = pivot.drop(columns=group_cols)
    return pivot


# Output helpers

def save_table(df, name, output_dir, caption=None, label=None):
    if df is None or df.empty:
        print(f"[!] Skipping empty table: {name}")
        return

    tables_dir = os.path.join(output_dir, "tables")
    os.makedirs(tables_dir, exist_ok=True)

    csv_path = os.path.join(tables_dir, f"{name}.csv")
    md_path = os.path.join(tables_dir, f"{name}.md")
    tex_path = os.path.join(tables_dir, f"{name}.tex")

    df.to_csv(csv_path, index=False)

    with open(md_path, "w") as f:
        f.write(df.to_markdown(index=False))

    latex_body = df.to_latex(index=False, escape=True)
    with open(tex_path, "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n")
        f.write(latex_body)
        if caption:
            f.write(f"\\caption{{{caption}}}\n")
        if label:
            f.write(f"\\label{{{label}}}\n")
        f.write("\\end{table}\n")

    print(f"[+] Table  -> {csv_path} / .md / .tex")


def save_figure(fig, name, output_dir):
    figures_dir = os.path.join(output_dir, "figures")
    os.makedirs(figures_dir, exist_ok=True)

    png_path = os.path.join(figures_dir, f"{name}.png")
    pdf_path = os.path.join(figures_dir, f"{name}.pdf")
    fig.savefig(png_path, dpi=300, bbox_inches="tight")
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)

    print(f"[+] Figure -> {png_path} / .pdf")


# baseline decomposition (VUS=1)

def analyze_baseline(df, output_dir):
    base = df[df["phase"] == "baseline"]
    if base.empty:
        print("[!] No phase='baseline' data found; skipping E1 analysis.")
        return

    order = [t for t in TIER_ORDER if t in base["tier"].unique()]
    if not order:
        print("[!] No recognized tiers in baseline data; skipping E1 analysis.")
        return

    n_reps = base["rep"].nunique()
    print(f"[*] E1 baseline: {n_reps} independent repetition(s) detected.")

    e2e = base[(base["metric"] == "http_req_duration") & base["value"].notna()]

    # Table 1: pooled within-run end-to-end latency per target (all reps combined)
    rows = [summarize(e2e[e2e["tier"] == t]["value"], _tier_label(t)) for t in order]
    table1 = pd.DataFrame([r for r in rows if r])
    save_table(table1, "table1_baseline_e2e_latency_pooled", output_dir,
               caption="End-to-end request latency by strategy/tier at VUS=1, pooled across all repetitions "
                       "(within-run bootstrap CIs; see Table 1b for between-run reproducibility).",
               label="tab:baseline-e2e-pooled")

    # Table 1b: between-run (clean-slate) reproducibility of end-to-end latency
    table1b = between_run_consistency(base, "http_req_duration", "baseline", ["tier"],
                                       lambda k: _tier_label(k[0]))
    save_table(table1b, "table1b_baseline_between_run_consistency", output_dir,
               caption="Between-run consistency of mean end-to-end latency across independent, "
                       "clean-slate repetitions of the baseline phase.",
               label="tab:baseline-between-run")

    # Table 2: mean Python-side decomposition per target (pooled across reps)
    decomp_rows = []
    for t in order:
        row = {"Group": _tier_label(t)}
        for metric in PYTHON_TELEMETRY_METRICS:
            vals = base[(base["metric"] == metric) & (base["tier"] == t)]["value"]
            row[metric] = round(float(vals.mean()), 3) if not vals.empty else np.nan
        decomp_rows.append(row)
    table2 = pd.DataFrame(decomp_rows)
    save_table(table2, "table2_baseline_python_decomposition_mean_ms", output_dir,
               caption="Mean Python-side latency decomposition (ms) by tier at VUS=1, pooled across all repetitions.",
               label="tab:baseline-decomp")

    # Table 3: DataFrame-construction share of measured computation time
    share_rows = []
    for t in order:
        if t == "mock":
            continue
        df_t = base[(base["metric"] == "python_dataframe_construction_time_ms") & (base["tier"] == t)]["value"]
        inf_t = base[(base["metric"] == "python_model_inference_time_ms") & (base["tier"] == t)]["value"]
        comp_t = base[(base["metric"] == "python_computation_time_ms") & (base["tier"] == t)]["value"]
        if df_t.empty or inf_t.empty or comp_t.empty:
            continue
        comp_mean = float(comp_t.mean())
        share_rows.append({
            "Tier": _tier_label(t),
            "Mean DataFrame Construction (ms)": round(float(df_t.mean()), 3),
            "Mean Model Inference (ms)": round(float(inf_t.mean()), 3),
            "Mean Computation Total (ms)": round(comp_mean, 3),
            "DataFrame Share of Computation (%)": round(100 * float(df_t.mean()) / comp_mean, 1) if comp_mean else np.nan,
        })
    table3 = pd.DataFrame(share_rows)
    save_table(table3, "table3_dataframe_share_of_computation", output_dir,
               caption="DataFrame construction as a share of total measured computation time, by tier "
                       "(pooled across all repetitions).",
               label="tab:df-share")

    # Table 5: pairwise significance between adjacent tiers (mock vs v5,
    # v5 vs v10, v10 vs v20, v20 vs v28) -- answers "is the next tier
    # actually slower, or could that gap be noise" for each step.
    table5 = pairwise_mannwhitney(base, "http_req_duration", "baseline", "tier", order, _tier_label)
    save_table(table5, "table5_baseline_adjacent_tier_significance", output_dir,
               caption="Mann-Whitney U test between adjacent feature-count tiers, end-to-end latency "
                       "at VUS=1, pooled across all repetitions.",
               label="tab:baseline-mannwhitney")

    # Figure 1: stacked bar of Python-side decomposition, AI tiers only
    ai_order = [t for t in order if t != "mock"]
    if ai_order:
        stages = [
            ("python_parsing_time_ms", "Request Parsing"),
            ("python_dataframe_construction_time_ms", "DataFrame Construction"),
            ("python_model_inference_time_ms", "Model Inference"),
            ("python_serialization_time_ms", "Response Serialization"),
        ]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(ai_order))
        x_labels = [f"v{t}" for t in ai_order]
        for i, (metric, label) in enumerate(stages):
            vals = np.array([
                base[(base["metric"] == metric) & (base["tier"] == t)]["value"].mean() or 0.0
                for t in ai_order
            ])
            vals = np.nan_to_num(vals)
            ax.bar(x_labels, vals, bottom=bottoms, label=label,
                   color=COLOR_CYCLE[i % len(COLOR_CYCLE)], edgecolor="black", linewidth=0.5)
            bottoms += vals
        ax.set_xlabel("Feature Tier")
        ax.set_ylabel("Mean Latency (ms)")
        ax.set_title("Python-Side Latency Decomposition by Feature Tier (VUS=1, pooled)", fontweight="bold")
        ax.legend(fontsize=8, loc="upper left")
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
        save_figure(fig, "figure1_baseline_decomposition_stacked_bar", output_dir)

    # Figure 2: end-to-end latency distribution per target (pooled)
    fig, ax = plt.subplots(figsize=(9, 5), dpi=300)
    for i, t in enumerate(order):
        vals = e2e[e2e["tier"] == t]["value"]
        if vals.empty:
            continue
        ax.hist(vals, bins=40, alpha=0.55, label=_tier_label(t),
                color=COLOR_CYCLE[i % len(COLOR_CYCLE)], edgecolor="black", linewidth=0.3)
    ax.set_title("End-to-End Latency Distribution at Baseline (VUS=1, pooled across reps)", fontweight="bold")
    ax.set_xlabel("Request Latency (ms)")
    ax.set_ylabel("Frequency")
    ax.legend(title="Target", fontsize=8)
    ax.grid(True, linestyle="--", alpha=0.4)
    save_figure(fig, "figure2_baseline_latency_distribution", output_dir)

    # Figure 6: Between-run reproducibility (mean latency ± SD across independent reps).
    # Demonstrates session-to-session variance across clean-slate restarts.

    per_rep = e2e.groupby(["tier", "rep"])["value"].mean().reset_index()
    means, stds, labels = [], [], []
    for t in order:
        vals = per_rep[per_rep["tier"] == t]["value"].to_numpy()
        if len(vals) == 0:
            continue
        labels.append(_tier_label(t))
        means.append(vals.mean())
        stds.append(vals.std(ddof=1) if len(vals) > 1 else 0.0)
    if labels:
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        ax.bar(labels, means, yerr=stds, capsize=5, color=COLOR_CYCLE[0], edgecolor="black", linewidth=0.5)
        ax.set_xlabel("Target")
        ax.set_ylabel("Mean End-to-End Latency (ms)")
        ax.set_title(f"Between-Run Reproducibility, N={n_reps} Independent Runs "
                      f"(error bars = SD across runs)", fontweight="bold")
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
        save_figure(fig, "figure6_between_run_reproducibility_baseline", output_dir)


# concurrency scan

def analyze_scan(df, output_dir):
    scan = df[df["phase"] == "scan"]
    if scan.empty:
        print("[!] No phase='scan' data found; skipping E2 analysis.")
        return

    order = [t for t in TIER_ORDER if t in scan["tier"].unique()]
    seen_levels = sorted(int(v) for v in scan["vus"].dropna().unique())
    levels = [v for v in CONCURRENCY_ORDER if v in seen_levels] or seen_levels
    if not order or not levels:
        print("[!] No recognized tiers/concurrency levels in scan data; skipping E2 analysis.")
        return

    n_reps = scan["rep"].nunique()
    print(f"[*] E2 scan: {n_reps} independent repetition(s) detected.")

    e2e = scan[(scan["metric"] == "http_req_duration") & scan["value"].notna()]
    failed = scan[scan["metric"] == "http_req_failed"]


    rows = []
    for t in order:
        for vus in levels:
            cell = e2e[(e2e["tier"] == t) & (e2e["vus"] == vus)]
            if cell.empty:
                continue
            s = summarize(cell["value"], f"{_tier_label(t)} @ VUS={vus}")
            if not s:
                continue
            fail_cell = failed[(failed["tier"] == t) & (failed["vus"] == vus)]["value"]
            error_rate = round(100 * float(fail_cell.mean()), 2) if not fail_cell.empty else 0.0
            throughput = _throughput_reqs_per_s(cell)
            rows.append({
                "Tier": _tier_label(t),
                "Concurrency (VUS)": vus,
                **s,
                "Throughput (req/s)": round(throughput, 2) if not np.isnan(throughput) else np.nan,
                "Error Rate (%)": error_rate,
            })
    table4 = pd.DataFrame(rows)
    save_table(table4, "table4_concurrency_scan_summary_pooled", output_dir,
               caption="Latency, throughput, and error rate across the concurrency sweep, by tier, "
                       "pooled across all repetitions (see Table 4b for between-run reproducibility).",
               label="tab:scan-summary-pooled")

    # Table 4b: between-run consistency per (tier, concurrency) cell
    table4b = between_run_consistency(scan, "http_req_duration", "scan", ["tier", "vus"],
                                       lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}")
    save_table(table4b, "table4b_scan_between_run_consistency", output_dir,
               caption="Between-run consistency of mean end-to-end latency across independent, "
                       "clean-slate repetitions of the concurrency scan.",
               label="tab:scan-between-run")

    # Table 6: Pairwise significance between adjacent concurrency levels per tier.
    # Evaluates whether each incremental concurrency increase significantly degrades latency.
    table6_parts = []
    for t in order:
        part = pairwise_mannwhitney(
            scan, "http_req_duration", "scan", "vus", levels,
            lambda v: f"VUS={int(v)}", fixed_filters={"tier": t},
        )
        if not part.empty:
            part.insert(0, "Tier", _tier_label(t))
            table6_parts.append(part)
    table6 = pd.concat(table6_parts, ignore_index=True) if table6_parts else pd.DataFrame()
    save_table(table6, "table6_scan_adjacent_concurrency_significance", output_dir,
               caption="Mann-Whitney U test between adjacent concurrency levels, end-to-end latency, "
                       "per tier, pooled across all repetitions.",
               label="tab:scan-mannwhitney")

    # Figure 3: P95 end-to-end latency vs. concurrency, with error bars
    # from the SD of per-rep P95 across independent repetitions.
    fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
    for i, t in enumerate(order):
        xs, ys, yerrs = [], [], []
        for vus in levels:
            cell = e2e[(e2e["tier"] == t) & (e2e["vus"] == vus)]
            if cell.empty:
                continue
            per_rep_p95 = cell.groupby("rep")["value"].apply(lambda s: np.percentile(s, 95))
            if per_rep_p95.empty:
                continue
            xs.append(vus)
            ys.append(per_rep_p95.mean())
            yerrs.append(per_rep_p95.std(ddof=1) if len(per_rep_p95) > 1 else 0.0)
        if xs:
            ax.errorbar(xs, ys, yerr=yerrs, marker="o", capsize=3, label=_tier_label(t),
                         color=COLOR_CYCLE[i % len(COLOR_CYCLE)])
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Concurrency (VUs, log scale)")
    ax.set_ylabel("P95 End-to-End Latency (ms)")
    ax.set_title(f"P95 Latency vs. Concurrency by Tier (N={n_reps} runs, error bars = SD across runs)",
                 fontweight="bold")
    ax.legend(title="Target", fontsize=8)
    ax.grid(True, which="both", linestyle="--", alpha=0.4)
    save_figure(fig, "figure3_p95_latency_vs_concurrency", output_dir)

    # Figure 4: throughput vs. concurrency, one line per tier (pooled)
    fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
    for i, t in enumerate(order):
        xs, ys = [], []
        for vus in levels:
            cell = e2e[(e2e["tier"] == t) & (e2e["vus"] == vus)]
            if cell.empty:
                continue
            th = _throughput_reqs_per_s(cell)
            if np.isnan(th):
                continue
            xs.append(vus)
            ys.append(th)
        if xs:
            ax.plot(xs, ys, marker="o", label=_tier_label(t), color=COLOR_CYCLE[i % len(COLOR_CYCLE)])
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Concurrency (VUs, log scale)")
    ax.set_ylabel("Throughput (req/s)")
    ax.set_title("Throughput vs. Concurrency by Tier (pooled across runs)", fontweight="bold")
    ax.legend(title="Target", fontsize=8)
    ax.grid(True, which="both", linestyle="--", alpha=0.4)
    save_figure(fig, "figure4_throughput_vs_concurrency", output_dir)

    # Figure 5: how the compute decomposition itself shifts under load,
    # for the heaviest tier (v28)
    heaviest = "28" if "28" in order else next((t for t in reversed(order) if t != "mock"), None)
    if heaviest:
        stages = [
            ("python_dataframe_construction_time_ms", "DataFrame Construction"),
            ("python_model_inference_time_ms", "Model Inference"),
        ]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(levels))
        x_labels = [str(v) for v in levels]
        for i, (metric, label) in enumerate(stages):
            vals = np.array([
                scan[(scan["metric"] == metric) & (scan["tier"] == heaviest) & (scan["vus"] == vus)]["value"].mean() or 0.0
                for vus in levels
            ])
            vals = np.nan_to_num(vals)
            ax.bar(x_labels, vals, bottom=bottoms, label=label,
                   color=COLOR_CYCLE[i % len(COLOR_CYCLE)], edgecolor="black", linewidth=0.5)
            bottoms += vals
        ax.set_xlabel("Concurrency (VUs)")
        ax.set_ylabel("Mean Latency (ms)")
        ax.set_title(f"Compute Decomposition vs. Concurrency (Tier v{heaviest}, pooled)", fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
        save_figure(fig, f"figure5_decomposition_vs_concurrency_v{heaviest}", output_dir)



def main():
    parser = argparse.ArgumentParser(description="Analyze k6 results for the fraud-eval-harness testbed.")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR,
                         help="Directory containing k6 JSON-lines output files (default: ../results).")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                         help="Directory to write tables/ and figures/ into (default: ./output).")
    args = parser.parse_args()

    print(f"[*] Loading results from {args.results_dir} ...")
    df = load_results(args.results_dir)
    print(f"[*] Loaded {len(df)} metric points from {df['source_file'].nunique()} file(s).")

    analyze_baseline(df, args.output_dir)
    analyze_scan(df, args.output_dir)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()
