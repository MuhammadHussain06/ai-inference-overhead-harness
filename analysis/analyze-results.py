"""
Analyzes k6 load-test results from load-testing/run-suite.sh.

Computes latency distributions, scaling behavior, and run-to-run reproducibility
for the baseline (E1) and concurrency scan (E2) experiments. Significance tests
run on rep-level means (Holm-Bonferroni corrected, with rank-biserial effect
size) to avoid pseudoreplication. Latency tables cover HTTP 200 requests only,
each paired with an error-rate table.

Usage:
    python3 analyze-results.py [--results-dir ../results] [--output-dir ./output]
"""

import argparse
import glob
import json
import os
import re
import sys

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu
from statsmodels.stats.multitest import multipletests

DEFAULT_RESULTS_DIR = os.path.join(os.path.dirname(__file__), "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "output")

TIER_ORDER = ["calibration", "mock", "5", "10", "20", "28"]
CONCURRENCY_ORDER = [1, 2, 4, 8, 16, 32, 64]

PYTHON_TELEMETRY_METRICS = [
    "python_parsing_time_ms",
    "python_thread_dispatch_time_ms",
    "python_computation_time_ms",
    "python_dataframe_construction_time_ms",
    "python_model_inference_time_ms",
    "python_compute_stall_time_ms",
    "python_serialization_time_ms",
    "python_total_time_ms",
]

# Java-side estimate: aiCallRoundTripTimeMs minus Python's own totalPythonExecutionTimeMs.
# Not part of PYTHON_TELEMETRY_METRICS (different side of the wire, different meaning) but
# reported alongside it in Table 2 since it fills out the same latency decomposition.
JAVA_NETWORK_OVERHEAD_METRIC = "java_estimated_network_overhead_ms"

COLOR_CYCLE = ['#2b5c8f', '#c0392b', '#27ae60', '#8e44ad', '#e67e22', '#16a085']


def _tier_label(tier):
    if tier in (None, "", "mock"):
        return "mock"
    if tier == "calibration":
        return "calibration"
    return f"v{tier}"


def _rep_sort_key(r):
    try:
        return (0, int(r))
    except (TypeError, ValueError):
        return (1, str(r))


# Loading

def parse_run_failures(results_dir):
    """Returns raw lines from run_failures_log.txt, if any."""
    log_path = os.path.join(results_dir, "run_failures_log.txt")
    if not os.path.isfile(log_path):
        return []
    with open(log_path) as f:
        return [line.strip() for line in f if line.strip()]



def check_cpu_pin_log(results_dir):
    """Re-verifies cpu_pin_check_log.txt. run-suite.sh hard-aborts on a live
    mismatch, so this should always come back clean on a completed run."""
    log_path = os.path.join(results_dir, "cpu_pin_check_log.txt")
    if not os.path.isfile(log_path):
        print("[cpu-pin] No cpu_pin_check_log.txt found -- skipping verification.")
        return

    def kv(line):
        return dict(p.split("=", 1) for p in line.split() if "=" in p)

    pairs = [
        ("python_requested", "python_live"), ("java_requested", "java_live"),
        ("expected_from_cpuset", "jvm_effective_cpu_count"), ("k6_expected", "k6_live"),
        ("tiers_expected", "tiers_loaded"),
    ]
    n_checks = n_mismatches = 0
    mismatch_lines = []
    with open(log_path) as f:
        for line in f:
            if not line.startswith("cpu_pin_check"):
                continue
            fields = kv(line.strip())
            for expected_key, live_key in pairs:
                if expected_key in fields and live_key in fields:
                    n_checks += 1
                    if fields[expected_key] != fields[live_key]:
                        n_mismatches += 1
                        mismatch_lines.append(line.strip())
            if "n_jobs_verified" in fields:
                n_checks += 1
                if fields["n_jobs_verified"] != "true":
                    n_mismatches += 1
                    mismatch_lines.append(line.strip())

    if n_mismatches:
        print(f"[cpu-pin] WARNING: {n_mismatches}/{n_checks} checks mismatched "
              f"(unexpected -- run-suite.sh should have aborted on these):")
        for line in mismatch_lines:
            print(f"    {line}")
    else:
        print(f"[cpu-pin] {n_checks} checks verified, all matched.")


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
                    "rate": tags.get("rate"),
                    # HTTP status code; "0" means no response was received
                    "status": tags.get("status"),
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

def cluster_bootstrap_ci(sub_df, stat_fn, rep_col="rep", n_boot=2000, ci=0.95, seed=42):
    """
    Resamples whole repetitions (clusters) with replacement to pool requests, preserving
    internal request correlation and avoiding pseudoreplication from correlated within-run data.
    """
    reps = sub_df[rep_col].unique()
    if len(reps) < 2:
        return (np.nan, np.nan)
    rep_values = {r: sub_df.loc[sub_df[rep_col] == r, "value"].to_numpy() for r in reps}
    rng = np.random.default_rng(seed)
    boot_stats = np.empty(n_boot)
    for i in range(n_boot):
        chosen = rng.choice(reps, size=len(reps), replace=True)
        pooled = np.concatenate([rep_values[r] for r in chosen])
        boot_stats[i] = stat_fn(pooled)
    alpha = (1 - ci) / 2
    lo, hi = np.quantile(boot_stats, [alpha, 1 - alpha])
    return (float(lo), float(hi))


def summarize(sub_df, label, n_boot=2000):

    sub_df = sub_df[pd.to_numeric(sub_df["value"], errors="coerce").notna()].copy()
    sub_df["value"] = pd.to_numeric(sub_df["value"], errors="coerce")
    values = sub_df["value"].to_numpy()
    n = len(values)
    if n == 0:
        return None

    mean_lo, mean_hi = cluster_bootstrap_ci(sub_df, lambda s: np.mean(s), n_boot=n_boot)
    p95_lo, p95_hi = cluster_bootstrap_ci(sub_df, lambda s: np.percentile(s, 95), n_boot=n_boot)

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


def error_summary(df, phase, group_cols, label_fn):
    """
    Per-cell breakdown of successful, HTTP-error, and timeout/network-error
    requests, computed from http_req_duration points (one per attempted
    request, regardless of outcome).
    """
    sub = df[(df["metric"] == "http_req_duration") & (df["phase"] == phase)].copy()
    if sub.empty:
        return pd.DataFrame()

    sub["status"] = sub["status"].fillna("0")
    is_timeout = sub["status"] == "0"
    is_success = sub["status"] == "200"
    is_http_error = (~is_timeout) & (~is_success)
    sub["_is_timeout"] = is_timeout
    sub["_is_success"] = is_success
    sub["_is_http_error"] = is_http_error

    rows = []
    for key, g in sub.groupby(group_cols):
        key_tuple = key if isinstance(key, tuple) else (key,)
        total = len(g)
        n_success = int(g["_is_success"].sum())
        rows.append({
            "Group": label_fn(key_tuple),
            "Total Requests": total,
            "Successful (200)": n_success,
            "HTTP Errors (non-200 response)": int(g["_is_http_error"].sum()),
            "Timeouts / Network Errors (no response)": int(g["_is_timeout"].sum()),
            "Error Rate (%)": round(100 * (1 - n_success / total), 2) if total else np.nan,
        })
    return pd.DataFrame(rows)


def crosscheck_error_counters(df, phase, group_cols, label_fn, table_from_duration):
    """Cross-checks error_summary's http_req_duration-derived counts against k6's
    independent request_http_error/request_timeout_error counters."""
    counter_metrics = {
        "request_http_error": "HTTP Errors (non-200 response)",
        "request_timeout_error": "Timeouts / Network Errors (no response)",
    }
    sub = df[(df["phase"] == phase) & df["metric"].isin(counter_metrics.keys()) & df["value"].notna()].copy()
    if sub.empty or table_from_duration is None or table_from_duration.empty:
        return

    mismatches = []
    for metric, col in counter_metrics.items():
        counted = sub[sub["metric"] == metric].groupby(group_cols)["value"].sum()
        for key, group_total in counted.items():
            key_tuple = key if isinstance(key, tuple) else (key,)
            label = label_fn(key_tuple)
            row = table_from_duration[table_from_duration["Group"] == label]
            if row.empty:
                mismatches.append(f"{label}: no matching http_req_duration-derived row for {metric}")
                continue
            derived = row.iloc[0][col]
            if int(group_total) != int(derived):
                mismatches.append(
                    f"{label}: {metric} counter={int(group_total)} vs "
                    f"http_req_duration-derived '{col}'={int(derived)}"
                )

    if mismatches:
        print(f"[!] Error-count cross-check MISMATCH in phase='{phase}':")
        for m in mismatches:
            print(f"    - {m}")
    else:
        print(f"[+] Error-count cross-check OK for phase='{phase}'.")


def _throughput_reqs_per_s(subset_df):

    times = subset_df["time"].dropna()
    if len(times) < 2:
        return np.nan
    span_s = (times.max() - times.min()).total_seconds()
    if span_s <= 0:
        return np.nan
    return len(times) / span_s


def client_diagnostics_summary(df, phase, group_cols, label_fn, blocked_warn_ms=5.0):
    """
    k6's own http_req_blocked (time waiting for a free connection out of k6's
    pool) as a per-cell diagnostic -- a rise correlated with concurrency
    rather than tier points at the client, not the server under test.
    """
    sub = df[(df["metric"] == "http_req_blocked") & (df["phase"] == phase) & df["value"].notna()].copy()
    if sub.empty:
        return pd.DataFrame()

    rows = []
    for key, g in sub.groupby(group_cols):
        key_tuple = key if isinstance(key, tuple) else (key,)
        mean_ms = float(g["value"].mean())
        p95_ms = float(np.percentile(g["value"], 95))
        rows.append({
            "Group": label_fn(key_tuple),
            "Mean http_req_blocked (ms)": round(mean_ms, 4),
            "P95 http_req_blocked (ms)": round(p95_ms, 4),
            "Possible Client Contention": "YES" if p95_ms >= blocked_warn_ms else "no",
        })
    return pd.DataFrame(rows)


# Stats — significance

def rank_biserial_effect_size(U, n1, n2):
    """
    Rank-biserial correlation from a Mann-Whitney U statistic (equivalent to
    Cliff's delta). Ranges [-1, 1]; 0 = no separation between groups.
    """
    return 1 - (2 * U) / (n1 * n2)


def _effect_magnitude(delta):
    d = abs(delta)
    if d < 0.147:
        return "negligible"
    elif d < 0.33:
        return "small"
    elif d < 0.474:
        return "medium"
    else:
        return "large"


def _fmt_p(p):
    if p is None or (isinstance(p, float) and np.isnan(p)):
        return np.nan
    return f"{p:.2e}" if p < 0.001 else round(float(p), 4)


def pairwise_mannwhitney(df, metric, phase, group_col, order, label_fn, fixed_filters=None, rep_col="rep"):
    """
    Mann-Whitney U test between adjacent pairs in `order`, computed on
    rep-level means to avoid pseudoreplication from correlated within-run
    requests. Applies Holm-Bonferroni correction across the comparison
    family and reports rank-biserial effect size alongside each p-value.
    Also reports a pooled-request p-value, for reference only.

    fixed_filters: column constraints (e.g., {"vus": 64}) applied before
        comparison.
    """
    sub = df[(df["metric"] == metric) & (df["phase"] == phase) & df["value"].notna()]
    if fixed_filters:
        for col, val in fixed_filters.items():
            sub = sub[sub[col] == val]

    raw_rows = []
    for a, b in zip(order, order[1:]):
        pooled_a = sub[sub[group_col] == a]["value"].to_numpy()
        pooled_b = sub[sub[group_col] == b]["value"].to_numpy()

        rep_means_a = sub[sub[group_col] == a].groupby(rep_col)["value"].mean().to_numpy()
        rep_means_b = sub[sub[group_col] == b].groupby(rep_col)["value"].mean().to_numpy()

        # Requires >=2 reps per side for a valid rep-level test
        if len(rep_means_a) < 2 or len(rep_means_b) < 2:
            continue

        stat, p_rep = mannwhitneyu(rep_means_a, rep_means_b, alternative="two-sided")
        effect = rank_biserial_effect_size(stat, len(rep_means_a), len(rep_means_b))

        p_pooled = np.nan
        if len(pooled_a) >= 2 and len(pooled_b) >= 2:
            _, p_pooled = mannwhitneyu(pooled_a, pooled_b, alternative="two-sided")

        raw_rows.append({
            "Comparison": f"{label_fn(a)} vs {label_fn(b)}",
            "N reps (A)": len(rep_means_a),
            "N reps (B)": len(rep_means_b),
            "Median of rep-means A (ms)": round(float(np.median(rep_means_a)), 3),
            "Median of rep-means B (ms)": round(float(np.median(rep_means_b)), 3),
            "U statistic": round(float(stat), 1),
            "_p_rep_raw": p_rep,
            "Effect size (rank-biserial r)": round(float(effect), 3),
            "Effect magnitude": _effect_magnitude(effect),
            "Pooled N (A)": len(pooled_a),
            "Pooled N (B)": len(pooled_b),
            "p-value (pooled, diagnostic only)": _fmt_p(p_pooled),
        })

    if not raw_rows:
        return pd.DataFrame()

    pvals = [r["_p_rep_raw"] for r in raw_rows]
    reject, pvals_holm, _, _ = multipletests(pvals, alpha=0.05, method="holm")

    for r, p_holm, sig in zip(raw_rows, pvals_holm, reject):
        r["p-value (rep-level, uncorrected)"] = _fmt_p(r.pop("_p_rep_raw"))
        r["p-value (Holm-corrected)"] = _fmt_p(p_holm)
        r["Significant (Holm, alpha=0.05)"] = "Yes" if sig else "No"

    # Primary (corrected, rep-level) result first; pooled diagnostic last
    cols = ["Comparison", "N reps (A)", "N reps (B)",
            "Median of rep-means A (ms)", "Median of rep-means B (ms)",
            "U statistic", "p-value (rep-level, uncorrected)",
            "p-value (Holm-corrected)", "Significant (Holm, alpha=0.05)",
            "Effect size (rank-biserial r)", "Effect magnitude",
            "Pooled N (A)", "Pooled N (B)", "p-value (pooled, diagnostic only)"]
    return pd.DataFrame(raw_rows)[cols]


# Stats — between-run

def between_run_consistency(df, metric, phase, group_cols, label_fn):
    """
    Computes between-run Mean, SD, and CoV% across independent repetitions,
    using per-repetition means rather than pooled requests.
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


# warm-up convergence (post-hoc steady-state check)

def analyze_warmup(df, output_dir, window_size=100):
    """
    Post-hoc check of whether the fixed warm-up iteration budget reached a
    stable state, comparing P50 latency in the first vs. last window_size
    requests of each target's warm-up window per rep. Coarse, not a formal
    changepoint detector.
    """
    warm = df[(df["phase"] == "warmup") & (df["metric"] == "http_req_duration") &
              df["value"].notna() & (df["status"] == "200")].copy()
    if warm.empty:
        print("[!] No phase='warmup' data found (older results, or warm-up.js run without "
              "--out json=...); skipping warm-up convergence check.")
        return

    rows = []
    for (tier, source_file), g in warm.groupby(["tier", "source_file"]):
        g = g.sort_values("time")
        if len(g) < 2 * window_size:
            # Too few requests in this window to split cleanly; skip rather
            # than report a misleading number from an undersized sample.
            continue
        first_window = g["value"].iloc[:window_size]
        last_window = g["value"].iloc[-window_size:]
        p50_first = float(np.percentile(first_window, 50))
        p50_last = float(np.percentile(last_window, 50))
        pct_change = 100 * (p50_last - p50_first) / p50_first if p50_first else np.nan
        rows.append({
            "Tier": _tier_label(tier),
            "Source File": source_file,
            "N Requests": len(g),
            f"First {window_size} P50 (ms)": round(p50_first, 3),
            f"Last {window_size} P50 (ms)": round(p50_last, 3),
            "Change (%)": round(pct_change, 1) if not np.isnan(pct_change) else np.nan,
            "Stabilized (<10% drift)": "YES" if not np.isnan(pct_change) and abs(pct_change) < 10 else "no",
        })

    table = pd.DataFrame(rows)
    save_table(table, "table0_warmup_convergence_check", output_dir,
               caption=f"Per-rep, per-target warm-up convergence check: P50 latency in the first vs. "
                       f"last {window_size} requests of each target's warm-up window. Large drift "
                       f"indicates the warm-up period was insufficient to reach steady state for that target.",
               label="tab:warmup-convergence")


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

    # Latency computed on successful (200) requests only; see Table 1c for error rates
    e2e = base[(base["metric"] == "http_req_duration") & base["value"].notna() & (base["status"] == "200")]

    # Table 1: pooled within-run end-to-end latency per target (all reps combined, successful requests only)
    rows = [summarize(e2e[e2e["tier"] == t], _tier_label(t)) for t in order]
    table1 = pd.DataFrame([r for r in rows if r])
    save_table(table1, "table1_baseline_e2e_latency_pooled", output_dir,
               caption="End-to-end request latency by strategy/tier at VUS=1, pooled across all repetitions, "
                       "computed over successful (HTTP 200) requests only (within-run bootstrap CIs; see Table 1b "
                       "for between-run reproducibility and Table 1c for the error rate this excludes).",
               label="tab:baseline-e2e-pooled")

    # Table 1c: error/timeout breakdown per target
    table1c = error_summary(base, "baseline", ["tier"], lambda k: _tier_label(k[0]))
    save_table(table1c, "table1c_baseline_error_rates", output_dir,
               caption="Request outcome breakdown by target at VUS=1, pooled across all repetitions. "
                       "HTTP errors received a non-200 response; timeouts/network errors received no response "
                       "at all. Table 1's latency statistics are computed on the 'Successful (200)' subset only.",
               label="tab:baseline-error-rates")
    crosscheck_error_counters(df, "baseline", ["tier"], lambda k: _tier_label(k[0]), table1c)

    # Table 1d: client-side (k6) contention diagnostic
    table1d = client_diagnostics_summary(base, "baseline", ["tier"], lambda k: _tier_label(k[0]))
    save_table(table1d, "table1d_baseline_client_diagnostics", output_dir,
               caption="k6-side http_req_blocked per target at VUS=1 -- a diagnostic for client-side "
                       "connection contention, not a server-side latency measurement.",
               label="tab:baseline-client-diagnostics")

    # Table 1b: between-run (clean-slate) reproducibility of end-to-end latency.
    # Uses e2e (status==200 only), matching Table 1 -- see Table 5 comment.
    table1b = between_run_consistency(e2e, "http_req_duration", "baseline", ["tier"],
                                      lambda k: _tier_label(k[0]))
    save_table(table1b, "table1b_baseline_between_run_consistency", output_dir,
               caption="Between-run consistency of mean end-to-end latency across independent, "
                       "clean-slate repetitions of the baseline phase.",
               label="tab:baseline-between-run")

    # Table 2: Python-side mean latency decomposition and Java network overhead. Filtered
    # on status=="200" to maintain correctness independently of k6 metric emission logic.
    decomp_rows = []
    for t in order:
        row = {"Group": _tier_label(t)}
        for metric in PYTHON_TELEMETRY_METRICS:
            vals = base[(base["metric"] == metric) & (base["tier"] == t) & (base["status"] == "200")]["value"]
            row[metric] = round(float(vals.mean()), 3) if not vals.empty else np.nan
        net_vals = base[(base["metric"] == JAVA_NETWORK_OVERHEAD_METRIC) & (base["tier"] == t) & (base["status"] == "200")]["value"]
        row[JAVA_NETWORK_OVERHEAD_METRIC] = round(float(net_vals.mean()), 3) if not net_vals.empty else np.nan
        decomp_rows.append(row)
    table2 = pd.DataFrame(decomp_rows)
    save_table(table2, "table2_baseline_python_decomposition_mean_ms", output_dir,
               caption="Mean Python-side latency decomposition (ms) by tier at VUS=1, pooled across "
                       "repetitions, with the estimated network overhead (round-trip time minus "
                       "Python execution time) shown alongside. Occasional small negative values in "
                       "that column reflect estimation noise in the serialization-time measurement, "
                       "not a real negative transit time.",
               label="tab:baseline-decomp")

    # Table 3: DataFrame-construction share of measured computation time
    # (explicit status=="200" filter -- see Table 2 comment above)
    share_rows = []
    for t in order:
        if t in ("mock", "calibration"):
            continue
        df_t = base[(base["metric"] == "python_dataframe_construction_time_ms") & (base["tier"] == t) & (base["status"] == "200")]["value"]
        inf_t = base[(base["metric"] == "python_model_inference_time_ms") & (base["tier"] == t) & (base["status"] == "200")]["value"]
        comp_t = base[(base["metric"] == "python_computation_time_ms") & (base["tier"] == t) & (base["status"] == "200")]["value"]
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

    # Table 5: significance between adjacent tiers (mock vs v5, v5 vs v10, ...).
    # Uses e2e (status==200 only), consistent with Table 1/1b/2/3 above --
    # timeouts/HTTP errors must not be mixed into a latency comparison.
    table5 = pairwise_mannwhitney(e2e, "http_req_duration", "baseline", "tier", order, _tier_label)
    save_table(table5, "table5_baseline_adjacent_tier_significance", output_dir,
               caption="Mann-Whitney U test between adjacent feature-count tiers, end-to-end latency "
                       "at VUS=1. Tested on rep-level means (one independent observation per repetition) "
                       "to avoid pseudoreplication from correlated within-run requests; Holm-Bonferroni "
                       "corrected across the tier-comparison family. Rank-biserial effect size reported "
                       "alongside significance. Pooled-request p-value included for reference only.",
               label="tab:baseline-mannwhitney")

    # Figure 1: stacked bar of Python-side decomposition, AI tiers only
    ai_order = [t for t in order if t not in ("mock", "calibration")]
    if ai_order:
        stages = [
            ("python_parsing_time_ms", "Request Parsing"),
            ("python_thread_dispatch_time_ms", "Thread Dispatch"),
            ("python_dataframe_construction_time_ms", "DataFrame Construction"),
            ("python_model_inference_time_ms", "Model Inference"),
            ("python_compute_stall_time_ms", "Compute Stall (GIL/scheduling)"),
            ("python_serialization_time_ms", "Response Serialization"),
        ]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(ai_order))
        x_labels = [f"v{t}" for t in ai_order]
        for i, (metric, label) in enumerate(stages):
            vals = np.array([
                base[(base["metric"] == metric) & (base["tier"] == t) & (base["status"] == "200")]["value"].mean()
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

    # Figure 6: mean latency ± SD across independent reps
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

    # Latency computed on successful (200) requests only; see Table 4c for error rates
    e2e = scan[(scan["metric"] == "http_req_duration") & scan["value"].notna() & (scan["status"] == "200")]

    # Table 4c: error/timeout breakdown per (tier, concurrency) cell;
    # reused for the "Error Rate (%)" column in Table 4 below.
    table4c = error_summary(scan, "scan", ["tier", "vus"],
                            lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}")
    save_table(table4c, "table4c_scan_error_rates", output_dir,
               caption="Request outcome breakdown by tier and concurrency level, pooled across all "
                       "repetitions. HTTP errors received a non-200 response; timeouts/network errors "
                       "received no response at all. Table 4's latency statistics are computed on the "
                       "'Successful (200)' subset only -- no run was truncated or excluded based on "
                       "error thresholds.",
               label="tab:scan-error-rates")
    crosscheck_error_counters(df, "scan", ["tier", "vus"],
                              lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}", table4c)
    error_rate_lookup = dict(zip(table4c.get("Group", []), table4c.get("Error Rate (%)", [])))

    # Table 4d: client-side (k6) contention diagnostic, most relevant at the top of the concurrency sweep
    table4d = client_diagnostics_summary(scan, "scan", ["tier", "vus"],
                                         lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}")
    save_table(table4d, "table4d_scan_client_diagnostics", output_dir,
               caption="k6-side http_req_blocked per (tier, concurrency) cell -- a diagnostic for "
                       "client-side connection contention, checked before a throughput plateau at "
                       "high VUS is attributed to server-side capacity.",
               label="tab:scan-client-diagnostics")

    rows = []
    for t in order:
        for vus in levels:
            cell = e2e[(e2e["tier"] == t) & (e2e["vus"] == vus)]
            if cell.empty:
                continue
            s = summarize(cell, f"{_tier_label(t)} @ VUS={vus}")
            if not s:
                continue
            group_label = f"{_tier_label(t)} @ VUS={vus}"
            error_rate = error_rate_lookup.get(group_label, 0.0)
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
               caption="Latency (successful requests only), throughput, and error rate across the "
                       "concurrency sweep, by tier, pooled across all repetitions (see Table 4b for "
                       "between-run reproducibility and Table 4c for the full error/timeout breakdown).",
               label="tab:scan-summary-pooled")

    # Table 4b: between-run consistency per (tier, concurrency) cell.
    # Uses e2e (status==200 only), matching Table 4 -- see Table 5 comment.
    table4b = between_run_consistency(e2e, "http_req_duration", "scan", ["tier", "vus"],
                                      lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}")
    save_table(table4b, "table4b_scan_between_run_consistency", output_dir,
               caption="Between-run consistency of mean end-to-end latency across independent, "
                       "clean-slate repetitions of the concurrency scan.",
               label="tab:scan-between-run")

    # Table 6: Significance between adjacent concurrency levels per tier (status==200).
    # Excludes errors/timeouts to prevent concurrency-driven failures from skewing latency metrics.
    table6_parts = []
    for t in order:
        part = pairwise_mannwhitney(
            e2e, "http_req_duration", "scan", "vus", levels,
            lambda v: f"VUS={int(v)}", fixed_filters={"tier": t},
        )
        if not part.empty:
            part.insert(0, "Tier", _tier_label(t))
            table6_parts.append(part)
    table6 = pd.concat(table6_parts, ignore_index=True) if table6_parts else pd.DataFrame()
    save_table(table6, "table6_scan_adjacent_concurrency_significance", output_dir,
               caption="Mann-Whitney U test between adjacent concurrency levels, end-to-end latency, "
                       "per tier. Tested on rep-level means to avoid pseudoreplication; Holm-Bonferroni "
                       "corrected within each tier's family of concurrency-level comparisons. "
                       "Rank-biserial effect size reported alongside significance.",
               label="tab:scan-mannwhitney")

    # Figure 3: P95 latency vs. concurrency; error bars = SD of per-rep P95
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

    # Figure 5: Compute decomposition under load for feature tier 28. Isolate thread-pool
    # queueing (Thread Dispatch) from invariant steps (DataFrame Construction, Inference).
    heaviest = "28" if "28" in order else next((t for t in reversed(order) if t not in ("mock", "calibration")), None)
    if heaviest:
        stages = [
            ("python_thread_dispatch_time_ms", "Thread Dispatch"),
            ("python_dataframe_construction_time_ms", "DataFrame Construction"),
            ("python_model_inference_time_ms", "Model Inference"),
            ("python_compute_stall_time_ms", "Compute Stall (GIL/scheduling)"),
        ]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(levels))
        x_labels = [str(v) for v in levels]
        for i, (metric, label) in enumerate(stages):
            vals = np.array([
                scan[(scan["metric"] == metric) & (scan["tier"] == heaviest) & (scan["vus"] == vus) & (scan["status"] == "200")]["value"].mean()
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



GC_LINE_RE = re.compile(
    r"^\[[^\]]+\]\[(?P<uptime>[\d.]+)s\]\[(?P<level>[a-z]+)\s*\]\[(?P<tags>[^\]]+?)\s*\]\s*(?P<msg>.*)$"
)
GC_DUR_RE = re.compile(r"(?P<dur_ms>[\d.]+)ms\s*$")


def parse_gc_log(path):
    """Extracts (uptime_s, pause_ms) for each G1 pause event."""
    pauses = []
    first_uptime = last_uptime = None
    with open(path, errors="replace") as f:
        for line in f:
            m = GC_LINE_RE.match(line)
            if not m:
                continue
            uptime = float(m.group("uptime"))
            first_uptime = first_uptime if first_uptime is not None else uptime
            last_uptime = uptime
            if m.group("level") != "info" or m.group("tags") != "gc":
                continue
            msg = m.group("msg")
            if not msg.startswith("Pause"):
                continue
            dm = GC_DUR_RE.search(msg)
            if dm:
                pauses.append((uptime, float(dm.group("dur_ms"))))
    window_s = (last_uptime - first_uptime) if first_uptime is not None else None
    return pauses, window_s


def analyze_gc_logs(results_dir, output_dir):
    """Summarizes per-rep GC pause overhead from archived gc_<phase>_rep<N>.log files."""
    gc_logs_dir = os.path.join(results_dir, "gc-logs")
    if not os.path.isdir(gc_logs_dir):
        print("[gc] No gc-logs directory found -- skipping GC overhead analysis.")
        return

    name_re = re.compile(r"gc_(?P<phase>baseline|scan)_rep(?P<rep>\d+)\.log")
    rows = []
    for log_path in sorted(glob.glob(os.path.join(gc_logs_dir, "gc_*_rep*.log"))):
        m = name_re.match(os.path.basename(log_path))
        if not m:
            continue
        phase, rep = m.group("phase"), int(m.group("rep"))
        pauses, window_s = parse_gc_log(log_path)
        total_ms = sum(d for _, d in pauses)
        max_ms = max((d for _, d in pauses), default=0.0)
        overhead_pct = (total_ms / 1000.0 / window_s * 100.0) if window_s else None
        rows.append({
            "phase": phase, "rep": rep, "n_pauses": len(pauses),
            "total_pause_ms": round(total_ms, 2), "max_pause_ms": round(max_ms, 2),
            "window_s": round(window_s, 1) if window_s else None,
            "gc_overhead_pct": round(overhead_pct, 3) if overhead_pct is not None else None,
        })

    if not rows:
        print("[gc] gc-logs directory exists but no gc_<phase>_rep<N>.log files found -- skipping.")
        return

    gc_df = pd.DataFrame(rows).sort_values(["phase", "rep"])
    save_table(gc_df, "table_gc_overhead", output_dir,
               caption="Per-repetition JVM GC pause overhead (Unified JVM Logging, -Xlog:gc*).",
               label="tab:gc-overhead")

    high = gc_df[gc_df["gc_overhead_pct"] > 1.0]
    if not high.empty:
        print(f"[gc] WARNING: {len(high)} rep(s) show >1% of wall-clock time in GC pauses -- "
              f"see table_gc_overhead; GC may be contributing to tail latency.")
    else:
        print("[gc] GC pause overhead <=1% of wall-clock time in all reps.")

    fig, ax = plt.subplots(figsize=(8, 4))
    for phase, g in gc_df.groupby("phase"):
        ax.bar([f"{phase} r{r}" for r in g["rep"]], g["gc_overhead_pct"].fillna(0), label=phase)
    ax.set_ylabel("GC pause overhead (% of wall-clock time)")
    ax.set_title("Per-repetition JVM GC overhead")
    ax.legend()
    plt.xticks(rotation=45, ha="right")
    save_figure(fig, "fig_gc_overhead", output_dir)


def analyze_openloop_check(df, output_dir):
    """
    Optional: compares the manual open-loop (constant-arrival-rate) check
    against the main suite's closed-loop scan at VUS 32/64, per tier.
    Skipped silently if no openloop_*.json files are in --results-dir.
    """
    ol = df[df["source_file"].str.startswith("openloop") & (df["metric"] == "http_req_duration") &
            (df["status"] == "200")]
    if ol.empty:
        return

    dropped = df[df["source_file"].str.startswith("openloop") & (df["metric"] == "dropped_iterations")]

    rows = []
    for tier in sorted(ol["tier"].dropna().unique(), key=lambda t: TIER_ORDER.index(t) if t in TIER_ORDER else 99):
        ol_stats = summarize(ol[ol["tier"] == tier], f"{_tier_label(tier)} open-loop")
        if not ol_stats:
            continue
        rows.append({"Tier": _tier_label(tier), "Model": "Open-loop (constant-arrival-rate)",
                     "P95 (ms)": ol_stats["P95 (ms)"], "P99 (ms)": ol_stats["P99 (ms)"],
                     "N": ol_stats["N (pooled, all reps)"],
                     "Dropped iterations": int(dropped[dropped["tier"] == tier]["value"].sum())})

        for vus in (32, 64):
            cl_cell = df[(df["phase"] == "scan") & (df["metric"] == "http_req_duration") &
                         (df["status"] == "200") & (df["tier"] == tier) & (df["vus"] == vus)]
            cl_stats = summarize(cl_cell, f"{_tier_label(tier)} closed-loop VUS={vus}")
            if cl_stats:
                rows.append({"Tier": _tier_label(tier), "Model": f"Closed-loop VUS={vus}",
                             "P95 (ms)": cl_stats["P95 (ms)"], "P99 (ms)": cl_stats["P99 (ms)"],
                             "N": cl_stats["N (pooled, all reps)"], "Dropped iterations": "n/a"})

    if not rows:
        return

    table = pd.DataFrame(rows)
    save_table(table, "table7_openloop_validity_check", output_dir,
               caption="Open-loop (constant-arrival-rate) tail latency vs. the closed-loop scan at "
                       "VUS 32/64, for manually-checked tiers. Validates the concurrency scan against "
                       "coordinated omission; not part of the automated suite.",
               label="tab:openloop-validity")

    fig, ax = plt.subplots(figsize=(6, 4), dpi=300)
    tiers = table["Tier"].unique()
    models = table["Model"].unique()
    x = np.arange(len(tiers))
    width = 0.8 / max(len(models), 1)
    for i, m in enumerate(models):
        ys = [table.loc[(table["Tier"] == t) & (table["Model"] == m), "P99 (ms)"].mean() for t in tiers]
        ax.bar(x + i * width, ys, width, label=m)
    ax.set_xticks(x + width * (len(models) - 1) / 2)
    ax.set_xticklabels(tiers)
    ax.set_ylabel("P99 Latency (ms)")
    ax.set_title("Closed-loop vs. Open-loop P99 (validity check)", fontweight="bold")
    ax.legend(fontsize=7)
    save_figure(fig, "figure7_openloop_validity_check", output_dir)


def main():
    parser = argparse.ArgumentParser(description="Analyze k6 results for the fraud-eval-harness testbed.")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR,
                        help="Directory containing k6 JSON-lines output files (default: ../results).")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help="Directory to write tables/ and figures/ into (default: ./output).")
    args = parser.parse_args()

    print(f"[*] Loading results from {args.results_dir} ...")

    check_cpu_pin_log(args.results_dir)

    failures = parse_run_failures(args.results_dir)
    if failures:
        print(f"[!] {len(failures)} entries in run_failures_log.txt:")
        for line in failures:
            print(f"    {line}")
        print("[!] Exiting -- fix the cause and re-run the suite for a clean dataset.")
        sys.exit(1)

    df = load_results(args.results_dir)
    print(f"[*] Loaded {len(df)} metric points from {df['source_file'].nunique()} file(s).")

    analyze_warmup(df, args.output_dir)
    analyze_baseline(df, args.output_dir)
    analyze_scan(df, args.output_dir)
    analyze_gc_logs(args.results_dir, args.output_dir)
    analyze_openloop_check(df, args.output_dir)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()