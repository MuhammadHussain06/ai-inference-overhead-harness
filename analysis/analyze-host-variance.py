"""
Compares run-suite.sh runs from different hosts on metrics that do not scale with a
host's raw speed: ratios measured inside each run, paired by repetition, each with a
rep-level bootstrap CI, and each pair of runs tested for equivalence within a margin
on their ratio (TOST on the 90% CI). Absolute latency and throughput are
reported as host context only.

Runs are compared only when they agree on everything the harness or the operator
controls: measured code, run configuration, JVM pins, k6 image, per-service core
counts and CPU quotas, physical-core isolation, isolcpus coverage, IRQ balancing,
power source, governor, WSL2 and virtualization. Hardware and toolchain are reported, not gated.
--allow-env-mismatch compares anyway and states the mismatch in every caption.

Usage:
    python3 analyze-host-variance.py [RUN_DIR ...] [--results-dir ../results]
        [--output-dir ./output] [--margin-pct 10] [--allow-env-mismatch]
"""

import argparse
import gc
import importlib.util
import os
import re
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

ANALYSIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ANALYSIS_DIR, "lib"))
import hostvariance as hv  # noqa: E402
import run_dirs  # noqa: E402
import thermal  # noqa: E402
from report import save_figure, save_table  # noqa: E402


def _load_script(module_name, filename):
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(ANALYSIS_DIR, filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


results = _load_script("analyze_results", "analyze-results.py")

DEFAULT_RESULTS_DIR = os.path.join(ANALYSIS_DIR, "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(ANALYSIS_DIR, "output")
FILE_PREFIXES = ("table_hv", "figure_hv")

BASELINE_FILE_RE = re.compile(r"^baseline_(?P<tier>[a-z0-9]+)_rep(?P<rep>\d+)\.json(?:\.gz)?$")
SCAN_FILE_RE = re.compile(r"^scan_(?P<tier>[a-z0-9]+)_vus(?P<vus>\d+)_rep(?P<rep>\d+)\.json(?:\.gz)?$")
STAGES = (("python_thread_dispatch_time_ms", "Thread dispatch"),
          ("python_dataframe_construction_time_ms", "DataFrame construction"),
          ("python_model_inference_time_ms", "predict_proba()"))
TOTAL = "python_total_time_ms"
COMPUTE = "python_computation_time_ms"
AI_TIERS = ("5", "10", "20", "28")


# Per-cell summaries

def cell_summary(run_path, filename, phase, tier, vus):
    """HTTP 200 latency mean and P95, throughput, and mean Python stage times for one
    cell file, through analyze-results.py's own loader so every figure matches the
    per-run tables' treatment of sampling, status and timestamps."""
    stem = re.sub(r"\.json(?:\.gz)?$", "", filename)
    df, true_counts = results.load_results(run_path, prefixes=(f"{stem}.",))
    if df is None:
        return None
    ok = df[(df["metric"] == "http_req_duration") & (df["phase"] == phase)
            & (df["status"] == "200") & df["value"].notna()]
    if ok.empty:
        return None
    filters = dict(metric="http_req_duration", phase=phase, status="200", tier=tier)
    if vus is not None:
        filters["vus"] = vus
    summary = {
        "mean": float(ok["value"].mean()),
        "p95": float(np.percentile(ok["value"], 95)),
        "throughput": results._throughput_reqs_per_s(ok, true_counts=true_counts, **filters),
    }
    for metric in [m for m, _ in STAGES] + [TOTAL, COMPUTE]:
        values = df.loc[(df["metric"] == metric) & (df["phase"] == phase), "value"]
        summary[metric] = float(values.mean()) if not values.empty else np.nan
    return summary


def collect(run):
    """{(tier, rep): summary} for baseline cells and {(tier, vus, rep): summary} for scan
    cells, loading one cell file at a time so memory holds a single cell."""
    baseline, scan = {}, {}
    for i, name in enumerate(sorted(os.listdir(run.path))):
        m = BASELINE_FILE_RE.match(name)
        if m:
            s = cell_summary(run.path, name, "baseline", m["tier"], None)
            if s:
                baseline[(m["tier"], m["rep"])] = s
        else:
            m = SCAN_FILE_RE.match(name)
            if m:
                s = cell_summary(run.path, name, "scan", m["tier"], int(m["vus"]))
                if s:
                    scan[(m["tier"], int(m["vus"]), m["rep"])] = s
        if i % 25 == 0:
            gc.collect()
    return baseline, scan


def _series(cells, key_prefix, field):
    """{rep: cells[key][field]} for every key starting with key_prefix."""
    n = len(key_prefix)
    return {k[n]: v[field] for k, v in cells.items() if k[:n] == key_prefix}


def _mean_over_reps(cells, key_prefix, field):
    values = [v for v in _series(cells, key_prefix, field).values() if np.isfinite(v)]
    return float(np.mean(values)) if values else np.nan


# Metrics

def build_metrics(data, tiers, levels):
    """Host-portable metrics as numerator/denominator series per run, paired by rep."""
    lo, hi = min(levels), max(levels)
    ai = [t for t in tiers if t in AI_TIERS]
    metrics = []

    def add(family, metric, series):
        metrics.append({"family": family, "metric": metric, "series": series})

    for t in ai:
        add("Model computation / end-to-end latency (VUS=1)", results._tier_label(t),
            [(_series(b, (t,), COMPUTE), _series(b, (t,), "mean")) for b, _ in data])
    if "calibration" in tiers:
        for t in (t for t in tiers if t != "calibration"):
            add("Baseline latency / calibration (VUS=1)", results._tier_label(t),
                [(_series(b, (t,), "mean"), _series(b, ("calibration",), "mean")) for b, _ in data])
    for t in ai:
        for metric, label in STAGES:
            add("Share of Python total (VUS=1)", f"{label}, v{t}",
                [(_series(b, (t,), metric), _series(b, (t,), TOTAL)) for b, _ in data])
    if "calibration" in tiers:
        for t in (t for t in tiers if t != "calibration"):
            add(f"Throughput / calibration throughput (VUS={hi})", results._tier_label(t),
                [(_series(s, (t, hi), "throughput"), _series(s, ("calibration", hi), "throughput"))
                 for _, s in data])
    if lo != hi:
        for t in tiers:
            add(f"P95 at VUS={hi} / P95 at VUS={lo}", results._tier_label(t),
                [(_series(s, (t, hi), "p95"), _series(s, (t, lo), "p95")) for _, s in data])
    for t in ai:
        add(f"Share of Python total (VUS={hi})", f"Thread dispatch, v{t}",
            [(_series(s, (t, hi), STAGES[0][0]), _series(s, (t, hi), TOTAL)) for _, s in data])
    return metrics


def saturation_table(data, labels, tiers, levels):
    rows = []
    for t in tiers:
        row = {"Tier": results._tier_label(t)}
        for lab, (_, s) in zip(labels, data):
            level = hv.saturation_level(levels, [_mean_over_reps(s, (t, v), "throughput") for v in levels])
            row[lab] = level if level is not None else np.nan
        found = {row[lab] for lab in labels if pd.notna(row[lab])}
        row["Same on every run"] = "yes" if len(found) == 1 and all(pd.notna(row[lab]) for lab in labels) else "no"
        rows.append(row)
    return pd.DataFrame(rows)


def concordance_table(data, tiers, levels):
    hi = max(levels)
    rows = []
    for name, matrix in (
        ("Baseline mean latency (VUS=1)", [[_mean_over_reps(b, (t,), "mean") for t in tiers] for b, _ in data]),
        (f"Throughput (VUS={hi})", [[_mean_over_reps(s, (t, hi), "throughput") for t in tiers] for _, s in data]),
    ):
        m = np.asarray(matrix, dtype=float)
        if not np.isfinite(m).all():
            continue
        w, chi2, df_, p = hv.kendalls_w(m)
        orders = {tuple(np.argsort(row)) for row in m}
        rows.append({"Ordering of targets by": name, "Targets": len(tiers), "Runs": len(m),
                     "Kendall's W": round(w, 3) if np.isfinite(w) else np.nan,
                     "Chi-square": round(chi2, 2) if np.isfinite(chi2) else np.nan, "df": df_,
                     "p-value": hv.fmt_p(p), "Identical order on every run": "yes" if len(orders) == 1 else "no"})
    return pd.DataFrame(rows)


def context_table(runs, labels, data, tiers, levels):
    hi = max(levels)
    columns = {}
    for run, lab, (b, s) in zip(runs, labels, data):
        col = {}
        for t in tiers:
            col[f"Baseline mean latency, {results._tier_label(t)} (ms)"] = round(_mean_over_reps(b, (t,), "mean"), 3)
        for t in tiers:
            col[f"Throughput at VUS={hi}, {results._tier_label(t)} (req/s)"] = round(
                _mean_over_reps(s, (t, hi), "throughput"), 1)
        covs = []
        for t in tiers:
            for v in levels:
                means = [x for x in _series(s, (t, v), "mean").values() if np.isfinite(x)]
                if len(means) > 1 and np.mean(means):
                    covs.append(100 * np.std(means, ddof=1) / np.mean(means))
        col["Median between-rep CoV of scan cell means (%)"] = round(float(np.median(covs)), 2) if covs else np.nan
        col["Cells throttled on service cores"] = _throttled_cells(run)
        col["Max GC pause overhead (% of wall clock)"] = _max_gc_overhead(run)
        columns[lab] = col
    table = pd.DataFrame(columns)
    table.insert(0, "Quantity", table.index)
    return table.reset_index(drop=True)


def _throttled_cells(run):
    path = os.path.join(run.path, hv.ENV_TRACE_FILE["suite"])
    if not os.path.isfile(path):
        return "no trace"
    cores = run.metadata.get("cores_used_by_suite", {})
    cpusets = {svc: cores[key] for svc, key in results.SUITE_SERVICES if cores.get(key) not in (None, "", "unknown")}
    cells = thermal.cell_thermal(thermal.parse_env_trace(path), lambda cell: cpusets)
    cols = [c for c in cells.columns if c.endswith("_throttle_ms") and c != "pkg_throttle_ms"]
    if cells.empty or not cols or not cells[cols].notna().any().any():
        return "not exposed"
    return f"{int(cells[cols].fillna(0).gt(0).any(axis=1).sum())}/{len(cells)}"


def _max_gc_overhead(run):
    gc_dir = os.path.join(run.path, "gc-logs")
    overheads = []
    for name in sorted(os.listdir(gc_dir)) if os.path.isdir(gc_dir) else []:
        if re.match(r"^gc_(baseline|scan)_rep\d+\.log$", name):
            pauses, window_s, _ = results.parse_gc_log(os.path.join(gc_dir, name))
            if window_s:
                overheads.append(100 * sum(d for _, d in pauses) / 1000 / window_s)
    return round(max(overheads), 3) if overheads else np.nan


# Figures

def normalized_throughput_figure(data, labels, tiers, levels):
    cols = min(3, len(tiers))
    rows = int(np.ceil(len(tiers) / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(4 * cols, 3 * rows), dpi=300, squeeze=False, sharey=True)
    for ax, t in zip(axes.flat, tiers):
        for i, (lab, (_, s)) in enumerate(zip(labels, data)):
            means = np.array([_mean_over_reps(s, (t, v), "throughput") for v in levels])
            if np.isfinite(means).any() and np.nanmax(means) > 0:
                ax.plot(levels, means / np.nanmax(means), marker="o", markersize=3, label=lab,
                        color=hv.COLORS[i % len(hv.COLORS)])
        ax.set_xscale("log", base=2)
        ax.set_title(results._tier_label(t), fontsize=9)
        ax.grid(True, which="both", linestyle="--", alpha=0.4)
    for ax in list(axes.flat)[len(tiers):]:
        ax.set_visible(False)
    for ax in axes[:, 0]:
        ax.set_ylabel("Throughput / own peak")
    for ax in axes[-1, :]:
        ax.set_xlabel("Concurrency (VUs, log scale)")
    axes.flat[0].legend(fontsize=7)
    fig.suptitle("Throughput vs. concurrency, normalized to each run's own peak", fontweight="bold")
    fig.tight_layout()
    return fig


def main():
    parser = argparse.ArgumentParser(description="Compare run-suite.sh runs across hosts.")
    parser.add_argument("runs", nargs="*", help="Run directories, or directories holding them.")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR,
                        help="Where to look for runs when none are named (default: ../results).")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help="Root holding hostvariance/tables and hostvariance/figures (default: ./output).")
    parser.add_argument("--margin-pct", type=float, default=hv.DEFAULT_MARGIN_PCT,
                        help="Equivalence margin in percent (default: 10).")
    parser.add_argument("--allow-env-mismatch", action="store_true",
                        help="Compare runs whose gated environment differs, stating it in every caption.")
    args = parser.parse_args()

    try:
        runs = run_dirs.resolve(args.runs or [args.results_dir], "suite")
    except ValueError as e:
        print(f"[!] {e}")
        sys.exit(1)
    runs = hv.usable_runs(runs, lambda r: results.parse_run_failures(r.path))
    if len(runs) < 2:
        print(f"[!] Need at least two usable run-suite.sh runs; found {len(runs)}.")
        sys.exit(1)
    labels = hv.run_labels(runs)
    for run, lab in zip(runs, labels):
        print(f"[*] {lab}: {run.path}")

    date = datetime.now(timezone.utc).strftime("%Y%m%d")
    out = run_dirs.prepare_hostvariance_outputs(args.output_dir, FILE_PREFIXES, labels, date)

    note = hv.apply_gate(runs, labels, lambda r: r.metadata.get("suite_config"), out,
                         "table_hv0_environment", "tab:hv-environment", args.allow_env_mismatch)
    if note is None:
        sys.exit(1)

    data = []
    for run, lab in zip(runs, labels):
        print(f"[*] Summarizing {lab} ...")
        data.append(collect(run))
        gc.collect()

    tiers = [t for t in results.TIER_ORDER
             if all(any(k[0] == t for k in b) for b, _ in data) and all(any(k[0] == t for k in s) for _, s in data)]
    levels = sorted(set.intersection(*[{k[1] for k in s} for _, s in data])) if data else []
    if not tiers or not levels:
        print("[!] The runs share no tier and concurrency level with both baseline and scan data.")
        sys.exit(1)

    metrics = build_metrics(data, tiers, levels)
    if not metrics:
        print("[!] The runs' shared targets and levels yield no host-portable metric.")
        sys.exit(1)
    summary, pairwise = hv.compare(metrics, labels, args.margin_pct)
    bounds = hv.margin_text(args.margin_pct)
    save_table(summary, "table_hv1_portable_metrics", out,
               caption=f"Host-portable metrics per run: ratios measured within each run, paired by "
                       f"repetition, with 95% rep-level bootstrap CIs. The verdict tests every pair of "
                       f"runs by TOST: equivalent when the 90% CI of their percent difference lies within "
                       f"{bounds}, a {args.margin_pct:g}% margin on their ratio, symmetric on the log "
                       f"scale; different when it lies entirely outside." + note,
               label="tab:hv-portable-metrics")
    save_table(pairwise.drop(columns=[c for c in pairwise.columns if c.startswith("_")]),
               "table_hv2_pairwise_differences", out,
               caption=f"Percent difference of each metric between every pair of runs, the second "
                       f"named relative to the first, with 90% (equivalence test) and 95% bootstrap "
                       f"CIs; equivalence bounds {bounds}." + note,
               label="tab:hv-pairwise")
    save_table(saturation_table(data, labels, tiers, levels), "table_hv3_saturation_points", out,
               caption="Lowest concurrency level at which each run reaches 95% of its own peak "
                       "throughput, per tier." + note,
               label="tab:hv-saturation")
    p_floor = hv.kendalls_w_p_floor(len(data), len(tiers))
    floor_note = ""
    if p_floor > hv.ALPHA:
        floor_note = (f" With {len(data)} runs of {len(tiers)} targets the p-value cannot fall below "
                      f"{p_floor:.3f}, even for identical orderings; W and the identical-order column carry "
                      f"the agreement.")
        print(f"[!] Kendall's W:{floor_note}")
    save_table(concordance_table(data, tiers, levels), "table_hv4_order_concordance", out,
               caption="Agreement between runs on the ordering of targets, as Kendall's coefficient "
                       "of concordance W (1 = identical ranking) with its chi-square test." + floor_note + note,
               label="tab:hv-concordance")
    save_table(context_table(runs, labels, data, tiers, levels), "table_hv5_host_context", out,
               caption="Absolute figures per run. They differ with hardware by construction and are "
                       "reported for context, not compared." + note,
               label="tab:hv-context")
    save_figure(normalized_throughput_figure(data, labels, tiers, levels), "figure_hv1_normalized_throughput", out)
    fig = hv.forest_figure(pairwise, args.margin_pct, "Between-run differences in host-portable metrics")
    if fig is not None:
        save_figure(fig, "figure_hv2_pairwise_differences", out)

    counts = summary[hv.verdict_column(args.margin_pct)].value_counts().to_dict()
    print(f"\n[+] {len(summary)} metric(s): " + ", ".join(f"{v} {k}" for k, v in counts.items()))
    print(f"[+] Tables -> {out.tables}, figures -> {out.figures}")


if __name__ == "__main__":
    main()
