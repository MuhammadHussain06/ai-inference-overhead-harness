"""
Compares run-ablation.sh runs from different hosts on the size of each arm's effect
rather than on absolute latency: per arm, thread-dispatch and total Python time at the
value farthest from control relative to control, paired by repetition, each with a
rep-level bootstrap CI, and each pair of runs tested for equivalence within a margin
on their ratio (TOST on the 90% CI). Whether every run's effect points the same way is
reported alongside.

The environment gate is the one analyze-host-variance.py applies, with the ablation's
cpuset values compared by logical CPU count. --allow-env-mismatch compares anyway and
states the mismatch in every caption.

Usage:
    python3 analyze-ablation-host-variance.py [RUN_DIR ...] [--results-dir ../results]
        [--output-dir ./output] [--margin-pct 10] [--allow-env-mismatch]
"""

import argparse
import gc
import importlib.util
import os
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

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


ablation = _load_script("analyze_ablation", "analyze-ablation.py")

DEFAULT_RESULTS_DIR = os.path.join(ANALYSIS_DIR, "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(ANALYSIS_DIR, "output")
FILE_PREFIXES = ("table_ablation_hv", "figure_ablation_hv")
DISPATCH, TOTAL = "python_thread_dispatch_time_ms", "python_total_time_ms"
FAMILIES = ((DISPATCH, "Thread dispatch, extreme / control"), (TOTAL, "Python total, extreme / control"))


def _cpu_count_label(cpuset):
    return f"{len(hv.expand_cpuset(cpuset))} CPUs"


def _describe(arm, value):
    """An arm value as it compares across hosts: a cpuset by its logical CPU count."""
    return _cpu_count_label(value) if arm == "cpuset" else value


def _normalize_cell(cell):
    arm, value, cpuset, *rest = cell.split(":")
    cpus = _cpu_count_label(cpuset)
    return ":".join([arm, cpus if arm == "cpuset" else value, cpus, *rest])


def ablation_config(run):
    """The run's ablation_config with every cpuset replaced by its logical CPU count."""
    config = dict(run.metadata.get("ablation_config") or {})
    if not config:
        return None
    controls = dict(config.get("control_values") or {})
    if "cpuset" in controls:
        controls["cpuset"] = _cpu_count_label(controls["cpuset"])
    config["control_values"] = controls
    config["cells"] = [_normalize_cell(c) for c in config.get("cells", [])]
    return config


def _has_failures(run):
    log = os.path.join(run.path, "ablation_run_failures_log.txt")
    return os.path.isfile(log) and os.path.getsize(log) > 0


def collect(run):
    """{(arm, value, rep): {metric: mean}} per measured cell, one cell file at a time."""
    cells = {}
    for name in sorted(os.listdir(run.path)):
        if not ablation._is_cell_file(name):
            continue
        df, _ = ablation.load_ablation_cells(run.path, files=[os.path.join(run.path, name)])
        if df is None or df.empty:
            continue
        m = ablation.CELL_FILE_RE.match(name)
        cells[(m["arm"], m["value"], m["rep"])] = {
            metric: float(df.loc[df["metric"] == metric, "value"].mean()) for metric in (DISPATCH, TOTAL)}
        del df
        gc.collect()
    return cells


def comparisons(run, cells):
    """{arm: (control, extreme)}, chosen as analyze-ablation.py's planned comparison does."""
    controls = ablation.control_cells(run.metadata)
    chosen = {}
    for arm in sorted({k[0] for k in cells}):
        values = sorted({k[1] for k in cells if k[0] == arm}, key=ablation._value_sort_key)
        if len(values) < 2:
            continue
        control = controls.get(arm)
        chosen[arm] = ((control, ablation._extreme_value(values, control)) if control in values
                       else (values[0], values[-1]))
    return chosen


def _per_rep(cells, arm, value, metric):
    return {k[2]: v[metric] for k, v in cells.items() if k[0] == arm and k[1] == value}


def build_metrics(data, choices, arms):
    metrics = []
    for metric, family in FAMILIES:
        for arm in arms:
            control, extreme = choices[0][arm]
            name = f"{ablation.ARM_LABELS.get(arm, arm)}: {_describe(arm, extreme)} vs {_describe(arm, control)}"
            metrics.append({"family": family, "metric": name,
                            "series": [(_per_rep(c, arm, ch[arm][1], metric), _per_rep(c, arm, ch[arm][0], metric))
                                       for c, ch in zip(data, choices)]})
    return metrics


def context_table(runs, labels, data, choices, arms):
    columns = {}
    for run, lab, cells, ch in zip(runs, labels, data, choices):
        col = {}
        for arm in arms:
            control, extreme = ch[arm]
            ctrl = _per_rep(cells, arm, control, DISPATCH)
            ext = _per_rep(cells, arm, extreme, DISPATCH)
            name = ablation.ARM_LABELS.get(arm, arm)
            col[f"{name}: control thread dispatch (ms)"] = round(float(np.mean(list(ctrl.values()))), 3)
            if len(ctrl) >= 2 and len(ext) >= 2:
                u, p = mannwhitneyu(list(ctrl.values()), list(ext.values()), alternative="two-sided")
                col[f"{name}: Mann-Whitney p"] = hv.fmt_p(p)
                col[f"{name}: rank-biserial r"] = round(
                    float(ablation.rank_biserial_effect_size(u, len(ctrl), len(ext))), 3)
        rows = [{"metric": DISPATCH, "arm": k[0], "arm_value": k[1], "rep": k[2], "value": v[DISPATCH]}
                for k, v in cells.items()]
        agreement = ablation.build_control_agreement_table(pd.DataFrame(rows), controls=ablation.control_cells(run.metadata))
        col["Spread across control cells (%)"] = (agreement["Spread across control cells (%)"].iloc[0]
                                                  if "Spread across control cells (%)" in agreement else np.nan)
        col["Cells throttled on service cores"] = _throttled_cells(run)
        columns[lab] = col
    table = pd.DataFrame(columns)
    table.insert(0, "Quantity", table.index)
    return table.reset_index(drop=True)


def _throttled_cells(run):
    path = os.path.join(run.path, hv.ENV_TRACE_FILE["ablation"])
    if not os.path.isfile(path):
        return "no trace"
    cores = run.metadata.get("cores_used_by_suite", {})
    control = ablation.control_cells(run.metadata)["cpuset"]
    fixed = {svc: cores.get(key) for svc, key in (("java", "transaction_service_cpuset"), ("k6", "k6_cpuset"))
             if cores.get(key) not in (None, "", "unknown")}

    def cpusets(cell):
        key = ablation._cell_key(cell)
        return {"python": key[1] if key and key[0] == "cpuset" else control, **fixed}

    cells = thermal.cell_thermal(thermal.parse_env_trace(path), cpusets)
    cols = [c for c in cells.columns if c.endswith("_throttle_ms") and c != "pkg_throttle_ms"]
    if cells.empty or not cols or not cells[cols].notna().any().any():
        return "not exposed"
    return f"{int(cells[cols].fillna(0).gt(0).any(axis=1).sum())}/{len(cells)}"


def effect_figure(metrics, labels):
    rows = [m for m in metrics if m["family"] == FAMILIES[0][1]]
    fig, ax = plt.subplots(figsize=(max(6, 1.6 * len(rows)), 4), dpi=300)
    width = 0.8 / max(len(labels), 1)
    for i, lab in enumerate(labels):
        est, lo, hi = [], [], []
        for m in rows:
            e, boot = hv.ratio_bootstrap(*m["series"][i], (m["family"], m["metric"], lab))
            ci = np.nanpercentile(boot, [2.5, 97.5]) if boot is not None else (np.nan, np.nan)
            est.append(e)
            lo.append(max(e - ci[0], 0) if np.isfinite(ci[0]) else 0)
            hi.append(max(ci[1] - e, 0) if np.isfinite(ci[1]) else 0)
        x = np.arange(len(rows)) + i * width
        ax.bar(x, est, width, yerr=[lo, hi], capsize=3, label=lab, color=hv.COLORS[i % len(hv.COLORS)])
    ax.axhline(1, color="#333333", linewidth=0.8)
    ax.set_xticks(np.arange(len(rows)) + width * (len(labels) - 1) / 2)
    ax.set_xticklabels([m["metric"].replace(": ", ":\n") for m in rows], fontsize=7)
    ax.set_ylabel("Thread dispatch, extreme / control")
    ax.set_title("Ablation effect size per run (95% CI)", fontweight="bold")
    ax.legend(fontsize=7)
    ax.grid(True, axis="y", linestyle="--", alpha=0.4)
    return fig


def main():
    parser = argparse.ArgumentParser(description="Compare run-ablation.sh runs across hosts.")
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
        runs = run_dirs.resolve(args.runs or [args.results_dir], "ablation")
    except ValueError as e:
        print(f"[!] {e}")
        sys.exit(1)
    runs = hv.usable_runs(runs, _has_failures)
    if len(runs) < 2:
        print(f"[!] Need at least two usable run-ablation.sh runs; found {len(runs)}.")
        sys.exit(1)
    labels = hv.run_labels(runs)
    for run, lab in zip(runs, labels):
        print(f"[*] {lab}: {run.path}")

    date = datetime.now(timezone.utc).strftime("%Y%m%d")
    out = run_dirs.prepare_hostvariance_outputs(args.output_dir, FILE_PREFIXES, labels, date)

    note = hv.apply_gate(runs, labels, ablation_config, out, "table_ablation_hv0_environment",
                         "tab:ablation-hv-environment", args.allow_env_mismatch,
                         caption=hv.ENV_CAPTION + " The cpuset arm's values are compared by logical CPU count.")
    if note is None:
        sys.exit(1)

    data = []
    for run, lab in zip(runs, labels):
        print(f"[*] Summarizing {lab} ...")
        data.append(collect(run))
    choices = [comparisons(run, cells) for run, cells in zip(runs, data)]
    arms = [a for a in ablation.ARM_LABELS
            if all(a in ch for ch in choices)
            and len({(_describe(a, ch[a][0]), _describe(a, ch[a][1])) for ch in choices}) == 1]
    skipped = sorted({a for ch in choices for a in ch} - set(arms))
    if skipped:
        print(f"[!] Arms not measured identically on every run, left out: {', '.join(skipped)}")
    if not arms:
        print("[!] No ablation arm was measured the same way on every run.")
        sys.exit(1)

    metrics = build_metrics(data, choices, arms)
    summary, pairwise = hv.compare(metrics, labels, args.margin_pct)
    summary.insert(len(summary.columns) - 1, "Same direction on every run",
                   [hv.same_direction(m["series"]) for m in metrics])
    bounds = hv.margin_text(args.margin_pct)
    save_table(summary, "table_ablation_hv1_effect_ratios", out,
               caption=f"Each arm's effect per run: thread-dispatch and total Python time at the value "
                       f"farthest from control relative to control, paired by repetition, with 95% "
                       f"rep-level bootstrap CIs. The verdict tests every pair of runs by TOST: "
                       f"equivalent when the 90% CI of their percent difference lies within {bounds}, a "
                       f"{args.margin_pct:g}% margin on their ratio, symmetric on the log scale."
                       + note,
               label="tab:ablation-hv-effects")
    save_table(pairwise.drop(columns=[c for c in pairwise.columns if c.startswith("_")]),
               "table_ablation_hv2_pairwise_differences", out,
               caption=f"Percent difference of each arm's effect between every pair of runs, the second "
                       f"named relative to the first, with 90% and 95% bootstrap CIs; equivalence bounds "
                       f"{bounds}." + note,
               label="tab:ablation-hv-pairwise")
    save_table(context_table(runs, labels, data, choices, arms), "table_ablation_hv3_host_context", out,
               caption="Per run: absolute control-cell thread dispatch, each arm's own Mann-Whitney test "
                       "of control against extreme, the spread between the control cells, and thermal "
                       "throttling. Absolute values differ with hardware and are reported, not compared."
                       + note,
               label="tab:ablation-hv-context")
    save_figure(effect_figure(metrics, labels), "figure_ablation_hv1_effect_ratios", out)
    fig = hv.forest_figure(pairwise, args.margin_pct, "Between-run differences in ablation effect size")
    if fig is not None:
        save_figure(fig, "figure_ablation_hv2_pairwise_differences", out)

    counts = summary[hv.verdict_column(args.margin_pct)].value_counts().to_dict()
    print(f"\n[+] {len(summary)} metric(s): " + ", ".join(f"{v} {k}" for k, v in counts.items()))
    print(f"[+] Tables -> {out.tables}, figures -> {out.figures}")


if __name__ == "__main__":
    main()
