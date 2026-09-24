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
import gc
import glob
import gzip
import json
import os
import random
import re
import sys
from datetime import datetime

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu
from statsmodels.stats.multitest import multipletests

ANALYSIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ANALYSIS_DIR, "lib"))
import thermal  # noqa: E402
import warmup_check  # noqa: E402

warmup_gate = warmup_check.gate

DEFAULT_RESULTS_DIR = os.path.join(ANALYSIS_DIR, "..", "results")
DEFAULT_OUTPUT_DIR = os.path.join(ANALYSIS_DIR, "output")

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
# Docker bridge-network and HTTP/serialization overhead between the two containers, not
# a real network hop. Not part of PYTHON_TELEMETRY_METRICS (different side of the wire,
# different meaning) but reported alongside it in Table 2 since it fills out the same
# latency decomposition. Name must match common.js's Trend metric name exactly.
JAVA_BRIDGE_OVERHEAD_METRIC = "java_estimated_bridge_overhead_ms"

COLOR_CYCLE = ['#2b5c8f', '#c0392b', '#27ae60', '#8e44ad', '#e67e22', '#16a085']


def _tier_label(tier):
    if tier in (None, ""):
        # An untagged row is a harness fault, not the mock arm; keep the two distinguishable.
        return "unknown"
    if tier in ("mock", "calibration"):
        return tier
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



# Live values read from a container's cgroup, which run-suite.sh skips rather than
# aborts on when the cgroup does not expose them.
CGROUP_LIVE_KEYS = frozenset({"python_live", "java_live", "k6_live"})


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
    smt_unverifiable = n_skipped = 0
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("smt_check"):
                # Physical-core disjointness: run-suite.sh aborts on an overlap, so the
                # only outcome worth surfacing here is a host that could not be checked.
                n_checks += 1
                if kv(line).get("status") == "unverifiable":
                    smt_unverifiable += 1
                continue
            if not line.startswith("cpu_pin_check"):
                continue
            fields = kv(line)
            if fields.get("result") == "WARN_SKIPPED":
                n_skipped += 1
                continue
            for expected_key, live_key in pairs:
                # An unreadable live cgroup cpuset is a check run-suite.sh skipped
                # (result=WARN_SKIPPED), not a mismatch.
                if live_key in CGROUP_LIVE_KEYS and fields.get(live_key) in ("EMPTY", "UNREADABLE"):
                    continue
                if expected_key in fields and live_key in fields:
                    n_checks += 1
                    if fields[expected_key] != fields[live_key]:
                        n_mismatches += 1
                        mismatch_lines.append(line)
            if "n_jobs_verified" in fields:
                n_checks += 1
                if fields["n_jobs_verified"] != "true":
                    n_mismatches += 1
                    mismatch_lines.append(line)

    if n_skipped:
        print(f"[cpu-pin] NOTE: {n_skipped} live cgroup cpuset check(s) were skipped by the harness "
              f"(cgroup not readable, WARN_SKIPPED); live pinning is unverified there and only the "
              f"requested cpuset is on record.")
    if smt_unverifiable:
        print(f"[cpu-pin] NOTE: {smt_unverifiable} SMT topology check(s) reported 'unverifiable' "
              f"(thread_siblings_list not exposed, common under WSL2). Physical-core isolation is "
              f"undemonstrated for this dataset; see run_metadata.json.")

    if n_mismatches:
        print(f"[cpu-pin] WARNING: {n_mismatches}/{n_checks} checks mismatched "
              f"(unexpected -- run-suite.sh should have aborted on these):")
        for line in mismatch_lines:
            print(f"    {line}")
    else:
        print(f"[cpu-pin] {n_checks} checks verified, all matched.")


# Emitted by k6's engine outside any HTTP request context, so they never carry the
# per-request tags the load scripts attach.
K6_ENGINE_METRICS = frozenset({
    "data_sent", "data_received", "iterations", "iteration_duration",
    "vus", "vus_max", "dropped_iterations",
})

# Counters whose exact sum a check depends on (truncated-cell detection, the
# error-count cross-check), and which are rare next to a per-request metric like
# http_req_duration. Reservoir sampling below is uniform per file, so without this
# exemption those few points would usually be sampled out and a truncated cell would
# read as clean instead of tripping the check meant to catch it.
ALWAYS_KEEP_METRICS = frozenset({"dropped_iterations", "request_http_error", "request_timeout_error"})


def load_results(results_dir, prefixes=None):
    """
    prefixes: optional tuple of filename prefixes to restrict loading to (e.g.
    ("scan_", "openloop_")). Used by main() to load baseline and scan/openloop
    data in two separate passes, so the larger scan dataset is never held in
    memory at the same time as baseline. Warm-up files are streamed by
    analyze_warmup() instead.

    Returns (df, true_counts). df holds one row per (possibly reservoir-
    subsampled) point; true_counts holds the true pre-subsampling point count,
    time span and value range per tag combination, for summarize()/
    error_summary()/_throughput_reqs_per_s() to report a request count,
    throughput or extreme that subsampling did not distort. Both are None if
    prefixes is given and no files in results_dir match it (distinct from
    results_dir being empty/missing entirely, which is still a hard error
    either way).
    """
    # run-suite.sh gzips each finalized cell (*.json.gz); plain *.json covers a
    # manually produced cell. Both patterns also match non-cell JSON written into
    # the results dir (run_metadata.json); the prefix filter below is what keeps
    # those out, so load_results is always called with prefixes.
    files = sorted(
        glob.glob(os.path.join(results_dir, "*.json"))
        + glob.glob(os.path.join(results_dir, "*.json.gz"))
    )
    if not files:
        raise FileNotFoundError(
            f"No result files found in {results_dir}. Run load-testing/run-suite.sh first."
        )
    if prefixes is not None:
        files = [f for f in files if os.path.basename(f).startswith(prefixes)]
        if not files:
            return None, None

    # Columnar accumulation instead of one dict per row: a per-row dict carries
    # its own object overhead on top of the 11 values it holds, multiplied by
    # every metric point, and from_records holds that list and the resulting
    # frame in memory at once. Eleven flat lists avoid both.
    col_metric, col_value, col_strategy, col_tier, col_vus = [], [], [], [], []
    col_phase, col_rep, col_rate, col_status, col_time, col_source = [], [], [], [], [], []

    # json.loads() does not intern, so each tag column -- a few dozen distinct
    # values repeated across millions of points -- would otherwise allocate a new
    # string object per point instead of sharing one per distinct value.
    def _intern_tag(v):
        return sys.intern(v) if type(v) is str else v

    # Cells are sized by wall-clock duration, not request count, so a trivial target
    # (mock, calibration) can log an order of magnitude more points than a model-
    # inference tier. Sampling each file down to a uniform random subset of this size
    # bounds memory regardless of throughput, and mean/percentile/bootstrap-CI
    # estimates remain unbiased at this sample size.
    MAX_POINTS_PER_FILE = 250_000
    rng = random.Random(42)

    # True (pre-subsampling) point count, time span and value range per tag
    # combination, built from every point seen regardless of whether the reservoir
    # below keeps it. summarize()/error_summary()/_throughput_reqs_per_s() read this
    # to report a request count, throughput or extreme that subsampling did not
    # distort; a few scalars per combination are cheap enough to keep unconditionally,
    # unlike the points themselves.
    true_acc = {}

    for fp in files:
        source_file = os.path.basename(fp)
        # Reservoir: the bounded, sampled population (high-volume per-request metrics).
        res_metric, res_value, res_strategy, res_tier, res_vus = [], [], [], [], []
        res_phase, res_rep, res_rate, res_status, res_time = [], [], [], [], []
        # Always-keep: ALWAYS_KEEP_METRICS points, unbounded but rare -- kept in a
        # separate list so appending to it never touches reservoir slots.
        keep_metric, keep_value, keep_strategy, keep_tier, keep_vus = [], [], [], [], []
        keep_phase, keep_rep, keep_rate, keep_status, keep_time = [], [], [], [], []
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
                    data = obj.get("data", {}) or {}
                    tags = data.get("tags", {}) or {}
                    metric = _intern_tag(obj.get("metric"))
                    value = data.get("value")
                    strategy = _intern_tag(tags.get("strategy"))
                    tier = _intern_tag(tags.get("tier"))
                    vus = _intern_tag(tags.get("vus"))
                    phase = _intern_tag(tags.get("phase"))
                    rep = _intern_tag(tags.get("rep"))
                    rate = _intern_tag(tags.get("rate"))
                    # HTTP status code; "0" means no response was received
                    status = _intern_tag(tags.get("status"))
                    time_val = data.get("time")

                    true_key = (metric, strategy, tier, phase, rep, vus, status, rate)
                    acc = true_acc.get(true_key)
                    if acc is None:
                        acc = true_acc[true_key] = [0, None, None, None, None, None, None]
                    acc[0] += 1
                    if time_val is not None:
                        # Compared on the padded key: Go trims trailing zeros from the
                        # fraction, so raw strings do not order numerically.
                        key = warmup_gate.ts_key(time_val)
                        if acc[1] is None or key < acc[1]:
                            acc[1], acc[3] = key, time_val
                        if acc[2] is None or key > acc[2]:
                            acc[2], acc[4] = key, time_val
                    if isinstance(value, (int, float)):
                        if acc[5] is None or value < acc[5]:
                            acc[5] = value
                        if acc[6] is None or value > acc[6]:
                            acc[6] = value

                    # Non-200 http_req_duration points are rare and kept in full so
                    # error_summary()'s status-derived counts stay exact and remain a
                    # genuine independent cross-check against the request_http_error/
                    # request_timeout_error counters, rather than an estimate derived
                    # from a random subsample of a metric that is mostly successes.
                    if (
                        metric in ALWAYS_KEEP_METRICS
                        or (metric == "http_req_duration" and status != "200")
                    ):
                        keep_metric.append(metric); keep_value.append(value); keep_strategy.append(strategy)
                        keep_tier.append(tier); keep_vus.append(vus); keep_phase.append(phase)
                        keep_rep.append(rep); keep_rate.append(rate); keep_status.append(status)
                        keep_time.append(time_val)
                        continue

                    n_seen += 1
                    # Algorithm R: the first MAX_POINTS_PER_FILE points are always kept;
                    # each point after that replaces a uniformly random existing slot with
                    # probability MAX_POINTS_PER_FILE/n_seen, which keeps every point seen
                    # so far equally likely to end up in the final sample.
                    if n_seen <= MAX_POINTS_PER_FILE:
                        res_metric.append(metric); res_value.append(value); res_strategy.append(strategy)
                        res_tier.append(tier); res_vus.append(vus); res_phase.append(phase)
                        res_rep.append(rep); res_rate.append(rate); res_status.append(status)
                        res_time.append(time_val)
                    else:
                        idx = rng.randint(0, n_seen - 1)
                        if idx < MAX_POINTS_PER_FILE:
                            res_metric[idx] = metric; res_value[idx] = value; res_strategy[idx] = strategy
                            res_tier[idx] = tier; res_vus[idx] = vus; res_phase[idx] = phase
                            res_rep[idx] = rep; res_rate[idx] = rate; res_status[idx] = status
                            res_time[idx] = time_val
            except (EOFError, OSError) as e:
                # Raised by the decompressor itself, not json.loads, so a truncated
                # .json.gz never surfaces as a malformed line. What decompressed
                # cleanly is still used rather than losing every other file.
                print(f"[!] {source_file}: compressed stream ended early after {lines_read} "
                      f"line(s) ({e}). Using what decompressed cleanly; the rest of this "
                      f"file is lost.")

        if n_seen > MAX_POINTS_PER_FILE:
            print(f"[!] {source_file}: {n_seen} points subsampled to {MAX_POINTS_PER_FILE} "
                  f"(uniform random sample) to bound memory.")
        col_metric.extend(res_metric); col_metric.extend(keep_metric)
        col_value.extend(res_value); col_value.extend(keep_value)
        col_strategy.extend(res_strategy); col_strategy.extend(keep_strategy)
        col_tier.extend(res_tier); col_tier.extend(keep_tier)
        col_vus.extend(res_vus); col_vus.extend(keep_vus)
        col_phase.extend(res_phase); col_phase.extend(keep_phase)
        col_rep.extend(res_rep); col_rep.extend(keep_rep)
        col_rate.extend(res_rate); col_rate.extend(keep_rate)
        col_status.extend(res_status); col_status.extend(keep_status)
        col_time.extend(res_time); col_time.extend(keep_time)
        col_source.extend([source_file] * (len(res_metric) + len(keep_metric)))

    if not col_metric:
        raise ValueError(f"No 'Point' metric records found across {len(files)} file(s) in {results_dir}.")

    df = pd.DataFrame({
        "metric": col_metric, "value": col_value, "strategy": col_strategy,
        "tier": col_tier, "vus": col_vus, "phase": col_phase, "rep": col_rep,
        "rate": col_rate, "status": col_status, "time": col_time, "source_file": col_source,
    })
    # Free the raw column lists before any further processing: the frame above no
    # longer needs them, and on the full suite holding both at once doubles peak
    # memory for no benefit.
    del col_metric, col_value, col_strategy, col_tier, col_vus
    del col_phase, col_rep, col_rate, col_status, col_time, col_source
    gc.collect()

    # float32 halves these columns' memory versus float64. k6 reports latencies to
    # tenth-millisecond precision and float32 keeps ~7 significant digits, which
    # covers the three decimals every reported statistic is rounded to.
    df["value"] = pd.to_numeric(df["value"], errors="coerce").astype(np.float32)
    df["vus"] = pd.to_numeric(df["vus"], errors="coerce").astype(np.float32)
    df["time"] = pd.to_datetime(df["time"], format="ISO8601", errors="coerce", utc=True)

    # to_datetime infers one format from the first row and coerces the rest to NaT.
    # Unparsed timestamps silently blank the throughput column, so surface them here.
    n_unparsed = int(df["time"].isna().sum())
    if n_unparsed:
        print(f"[!] {n_unparsed}/{len(df)} timestamps did not parse and became NaT. "
              f"Throughput and the within-cell drift check depend on them; check the k6 output format.")

    # A missing rep tag would merge every repetition into one cluster and silently
    # revert the whole analysis to pseudoreplication. K6_ENGINE_METRICS carry no
    # request tags by design and are excluded so the warning stays meaningful.
    n_untagged_reps = int(df.loc[~df["metric"].isin(K6_ENGINE_METRICS), "rep"].isna().sum())
    if n_untagged_reps:
        print(f"[!] {n_untagged_reps} per-request metric point(s) carry no 'rep' tag and are being "
              f"treated as rep=1. Rep-level statistics assume one repetition per clean-slate "
              f"restart. (k6 engine metrics, which carry no request tags by design and enter no "
              f"reported statistic, are excluded from this count.)")
    df["rep"] = df["rep"].fillna("1")

    # k6 exits 0 when a per-vu-iterations scenario hits maxDuration; unrun iterations are
    # booked as dropped_iterations, which a truncated cell would otherwise report silently.
    drops = df[df["metric"] == "dropped_iterations"]
    if not drops.empty:
        per_file = drops.groupby("source_file", observed=True)["value"].sum()
        stray = {f: int(v) for f, v in per_file.items()
                 if v > 0 and not str(f).startswith("openloop")}
        if stray:
            print(f"[!] {sum(stray.values())} iteration(s) were dropped in non-open-loop cell(s): "
                  f"{stray}. Those cells hit maxDuration and ran fewer requests than configured, "
                  f"so their iteration budget was not met -- treat their results as truncated.")

    # These columns hold a handful of distinct values repeated across every row, so
    # a categorical (integer codes plus one shared string table) costs far less than
    # an object column holding a separate string per row. Comparisons, .isin() and
    # .groupby() behave identically on a categorical.
    for col in ("metric", "strategy", "tier", "phase", "status", "source_file", "rep"):
        df[col] = df[col].astype("category")

    true_counts = pd.DataFrame([
        {"metric": k[0], "strategy": k[1], "tier": k[2], "phase": k[3], "rep": k[4],
         "vus": k[5], "status": k[6], "rate": k[7], "true_n": v[0],
         "true_min_time": v[3], "true_max_time": v[4], "true_min_value": v[5], "true_max_value": v[6]}
        for k, v in true_acc.items()
    ])
    if not true_counts.empty:
        # Mirrors the same normalization df's own rep/vus/time columns just went
        # through above, so a filter value taken from df (e.g. a groupby key) matches
        # true_counts on the same terms.
        true_counts["rep"] = true_counts["rep"].fillna("1")
        true_counts["vus"] = pd.to_numeric(true_counts["vus"], errors="coerce").astype(np.float32)
        true_counts["true_min_time"] = pd.to_datetime(
            true_counts["true_min_time"], format="ISO8601", errors="coerce", utc=True)
        true_counts["true_max_time"] = pd.to_datetime(
            true_counts["true_max_time"], format="ISO8601", errors="coerce", utc=True)

    return df, true_counts


def _true_n_and_span(true_counts, **filters):
    """True (pre-subsampling) point count and time span for the given tag filters
    against load_results()'s true_counts side channel, e.g. metric="http_req_duration",
    tier="28", phase="scan", status="200". A filter left out matches every value of
    that column. Returns (n, min_time, max_time); n is 0 and the times are None if
    true_counts is unavailable or nothing matches.
    """
    if true_counts is None or true_counts.empty:
        return 0, None, None
    sub = true_counts
    for col, val in filters.items():
        sub = sub[sub[col] == val]
    if sub.empty:
        return 0, None, None
    return int(sub["true_n"].sum()), sub["true_min_time"].min(), sub["true_max_time"].max()


def _true_value_range(true_counts, **filters):
    """True (pre-subsampling) minimum and maximum value for the given tag filters, or
    (None, None) where true_counts is unavailable or nothing matches. A sample's
    extremes shrink toward the middle as it is subsampled, unlike its percentiles."""
    if true_counts is None or true_counts.empty or "true_min_value" not in true_counts:
        return None, None
    sub = true_counts
    for col, val in filters.items():
        sub = sub[sub[col] == val]
    if sub.empty or sub["true_min_value"].isna().all():
        return None, None
    return float(sub["true_min_value"].min()), float(sub["true_max_value"].max())


# Stats -- within-run

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


def summarize(sub_df, label, n_boot=2000, true_counts=None, **true_filters):
    """true_counts/true_filters: when given, the returned "N (pooled, all reps)", "Min"
    and "Max" are the true pre-subsampling values from load_results()'s true_counts
    side channel rather than sub_df's own. Every other figure stays computed on
    sub_df itself: it remains a valid random sample of the distribution regardless
    of what the true population size was, and its mean and percentiles stay
    unbiased, unlike its extremes.
    """

    sub_df = sub_df[pd.to_numeric(sub_df["value"], errors="coerce").notna()].copy()
    sub_df["value"] = pd.to_numeric(sub_df["value"], errors="coerce")
    values = sub_df["value"].to_numpy()
    n = len(values)
    if n == 0:
        return None

    # Only the displayed count is corrected; std's ddof=1 guard below stays on the
    # sample size n actually used to compute it, not the (possibly much larger)
    # true population size.
    true_n, _, _ = _true_n_and_span(true_counts, **true_filters)
    reported_n = true_n if true_n else n
    true_min, true_max = _true_value_range(true_counts, **true_filters) if true_n else (None, None)

    mean_lo, mean_hi = cluster_bootstrap_ci(sub_df, lambda s: np.mean(s), n_boot=n_boot)
    p95_lo, p95_hi = cluster_bootstrap_ci(sub_df, lambda s: np.percentile(s, 95), n_boot=n_boot)

    return {
        "Group": label,
        "N (pooled, all reps)": reported_n,
        "Mean (ms)": round(float(values.mean()), 3),
        "Mean 95% CI": f"[{mean_lo:.2f}, {mean_hi:.2f}]",
        "Median (ms)": round(float(np.percentile(values, 50)), 3),
        "P95 (ms)": round(float(np.percentile(values, 95)), 3),
        "P95 95% CI": f"[{p95_lo:.2f}, {p95_hi:.2f}]",
        "P99 (ms)": round(float(np.percentile(values, 99)), 3),
        "StdDev (ms)": round(float(values.std(ddof=1)) if n > 1 else 0.0, 3),
        "Min (ms)": round(true_min if true_min is not None else float(values.min()), 3),
        "Max (ms)": round(true_max if true_max is not None else float(values.max()), 3),
    }


def error_summary(df, phase, group_cols, label_fn, true_counts=None):
    """true_counts: when given, "Successful (200)" is corrected to the true
    pre-subsampling count (see _true_n_and_span). HTTP Errors and Timeouts are
    already exact -- the reservoir keeps every non-200 http_req_duration point in
    full -- so Total Requests is rebuilt from the three (now all exact) parts
    instead of reusing len(g), and Error Rate is recomputed from the correction.
    """
    sub = df[(df["metric"] == "http_req_duration") & (df["phase"] == phase)].copy()
    if sub.empty:
        return pd.DataFrame()

    # status is categorical; filling with a value outside its categories raises,
    # so drop back to plain strings first.
    sub["status"] = sub["status"].astype("object").fillna("0")
    is_timeout = sub["status"] == "0"
    is_success = sub["status"] == "200"
    is_http_error = (~is_timeout) & (~is_success)
    sub["_is_timeout"] = is_timeout
    sub["_is_success"] = is_success
    sub["_is_http_error"] = is_http_error

    rows = []
    for key, g in sub.groupby(group_cols, observed=True):
        key_tuple = key if isinstance(key, tuple) else (key,)
        n_errors = int(g["_is_http_error"].sum())
        n_timeouts = int(g["_is_timeout"].sum())
        n_success = int(g["_is_success"].sum())
        true_success, _, _ = _true_n_and_span(
            true_counts, metric="http_req_duration", phase=phase, status="200",
            **dict(zip(group_cols, key_tuple)),
        )
        if true_success:
            n_success = true_success
        total = n_success + n_errors + n_timeouts
        rows.append({
            "Group": label_fn(key_tuple),
            "Total Requests": total,
            "Successful (200)": n_success,
            "HTTP Errors (non-200 response)": n_errors,
            "Timeouts / Network Errors (no response)": n_timeouts,
            "Error Rate (%)": round(100 * (1 - n_success / total), 2) if total else np.nan,
        })
    return pd.DataFrame(rows)


def crosscheck_error_counters(df, phase, group_cols, label_fn, table_from_duration):
    # Cross-checks error counts against independent k6 error and timeout counters.
    counter_metrics = {
        "request_http_error": "HTTP Errors (non-200 response)",
        "request_timeout_error": "Timeouts / Network Errors (no response)",
    }
    sub = df[(df["phase"] == phase) & df["metric"].isin(counter_metrics.keys()) & df["value"].notna()].copy()
    if table_from_duration is None or table_from_duration.empty:
        print(f"[!] phase='{phase}': no http_req_duration-derived table to cross-check "
              f"against -- error-count cross-check did not run for this phase.")
        return
    if sub.empty:
        # k6 emits a Counter's points only when .add() is called, so absent counters are
        # normal on a clean run -- but indistinguishable from a renamed or never-emitted one.
        # Report which case this is rather than staying silent.
        derived = 0
        for col in counter_metrics.values():
            if col in table_from_duration.columns:
                derived += int(pd.to_numeric(table_from_duration[col], errors="coerce").fillna(0).sum())
        if derived:
            print(f"[!] phase='{phase}': the http_req_duration-derived table reports {derived} "
                  f"error(s), but no request_http_error/request_timeout_error counter points "
                  f"exist -- the independent cross-check could not run for this phase.")
        else:
            print(f"[+] phase='{phase}': no errors in either source; error-count cross-check "
                  f"vacuous (no counter points emitted, none expected).")
        return

    mismatches = []
    for metric, col in counter_metrics.items():
        counted = sub[sub["metric"] == metric].groupby(group_cols, observed=True)["value"].sum()
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


def _throughput_reqs_per_s(subset_df, rep_col="rep", true_counts=None, **true_filters):
    """Mean of per-repetition throughput.

    Measured over each repetition separately and then averaged. Pooling the
    repetitions first is invalid: the span would then run from the first
    repetition's first request to the last repetition's last request, which
    includes every stack restart, warm-up and cooldown in between.

    true_counts/true_filters: when given, a rep whose true (pre-subsampling)
    count and time span are both available uses them instead of subset_df's own
    count and span, so throughput is not deflated by however much of that rep's
    scan cell the reservoir subsampled away.
    """
    per_rep = []
    for rep_val, g in subset_df.groupby(rep_col, observed=True):
        true_n, true_min, true_max = _true_n_and_span(true_counts, rep=rep_val, **true_filters)
        if true_n >= 2 and true_min is not None and true_max is not None:
            true_span_s = (true_max - true_min).total_seconds()
            if true_span_s > 0:
                per_rep.append((true_n - 1) / true_span_s)
                continue

        times = g["time"].dropna()
        if len(times) < 2:
            continue
        span_s = (times.max() - times.min()).total_seconds()
        if span_s > 0:
            # N completion timestamps bound N-1 inter-completion intervals, so the rate over
            # that span is (N-1)/span. N/span overestimates by a factor of N/(N-1), a bias
            # correlated with concurrency -- the axis Table 4 and Figure 4 display.
            per_rep.append((len(times) - 1) / span_s)
    return float(np.mean(per_rep)) if per_rep else np.nan


def client_diagnostics_summary(df, phase, group_cols, label_fn, blocked_warn_ms=5.0):
    # http_req_blocked is k6-side connection-pool wait, not server latency. Reported so a
    # throughput plateau can be attributed to the server only after ruling the client out.
    sub = df[(df["metric"] == "http_req_blocked") & (df["phase"] == phase) & df["value"].notna()].copy()
    if sub.empty:
        return pd.DataFrame()

    rows = []
    for key, g in sub.groupby(group_cols, observed=True):
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


# Stats -- significance

def rank_biserial_effect_size(U, n1, n2):
    """
    Rank-biserial correlation from a Mann-Whitney U statistic, on the same sign
    convention as Cliff's delta: delta = P(A > B) - P(A < B), computed from the U
    that scipy.stats.mannwhitneyu returns for the FIRST sample.

    Ranges [-1, 1]; 0 = no separation. NEGATIVE means group A's values are smaller
    than group B's, so along an increasing-latency axis (tier 5 -> 28) the expected
    sign is negative. Note the sign: the complementary form 1 - 2U/(n1*n2) carries
    the opposite convention and would report +1 where Cliff's delta is -1.
    """
    return (2 * U) / (n1 * n2) - 1


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


def _min_achievable_p(n1, n2):
    """
    Smallest two-sided Mann-Whitney p-value obtainable at sample sizes (n1, n2):
    the p-value at perfect separation (every value in one group below every
    value in the other). Computed by running mannwhitneyu on a synthetic
    perfectly-separated pair rather than a hand-derived formula, so it matches
    whatever exact/asymptotic method scipy selects for this n1/n2.
    """
    a = np.arange(n1, dtype=float)
    b = np.arange(n1, n1 + n2, dtype=float)
    _, p = mannwhitneyu(a, b, alternative="two-sided")
    return p


def pairwise_mannwhitney(df, metric, phase, group_col, order, label_fn, fixed_filters=None, rep_col="rep"):
    # Tests adjacent pairs in `order`, on rep-level means rather than pooled requests:
    # requests within one run are correlated, so a pooled test counts them as independent
    # observations and understates the p-value. Holm-Bonferroni corrects across the
    # adjacent-pair family; the pooled p-value is carried through for reference only.
    sub = df[(df["metric"] == metric) & (df["phase"] == phase) & df["value"].notna()]
    if fixed_filters:
        for col, val in fixed_filters.items():
            sub = sub[sub[col] == val]

    raw_rows = []
    for a, b in zip(order, order[1:]):
        pooled_a = sub[sub[group_col] == a]["value"].to_numpy()
        pooled_b = sub[sub[group_col] == b]["value"].to_numpy()

        rep_means_a = sub[sub[group_col] == a].groupby(rep_col, observed=True)["value"].mean().to_numpy()
        rep_means_b = sub[sub[group_col] == b].groupby(rep_col, observed=True)["value"].mean().to_numpy()

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
            "_min_achievable_p": _min_achievable_p(len(rep_means_a), len(rep_means_b)),
            "Effect size (rank-biserial r)": round(float(effect), 3),
            "Effect magnitude": _effect_magnitude(effect),
            "Pooled N (A)": len(pooled_a),
            "Pooled N (B)": len(pooled_b),
            "p-value (pooled, diagnostic only)": _fmt_p(p_pooled),
        })

    if not raw_rows:
        return pd.DataFrame()

    n_possible = len(order) - 1
    if len(raw_rows) < n_possible:
        print(f"[!] Holm correction for metric='{metric}' phase='{phase}' is over "
              f"{len(raw_rows)} comparison(s), not the {n_possible} the design specifies: "
              f"{n_possible - len(raw_rows)} adjacent pair(s) had fewer than 2 repetitions on "
              f"one side and were skipped. A smaller family means a weaker correction.")

    alpha = 0.05
    underpowered = [r for r in raw_rows if r["_min_achievable_p"] > alpha]
    if underpowered:
        comps = ", ".join(r["Comparison"] for r in underpowered)
        worst = max(r["_min_achievable_p"] for r in underpowered)
        print(f"[!] metric='{metric}' phase='{phase}': at this rep count, even perfect "
              f"separation cannot reach alpha={alpha} (best possible p={worst:.3g}) for: "
              f"{comps}. 'Significant (Holm, alpha=0.05): No' there reflects an underpowered "
              f"test, not evidence of no difference.")

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


# Stats -- between-run

def between_run_consistency(df, metric, phase, group_cols, label_fn):
    # One observation per repetition (its mean), so the reported SD and CoV measure
    # run-to-run spread rather than within-run request spread.

    sub = df[(df["metric"] == metric) & (df["phase"] == phase) & df["value"].notna()].copy()
    if sub.empty:
        return pd.DataFrame()

    per_rep_mean = sub.groupby(group_cols + ["rep"], observed=True)["value"].mean().reset_index()
    pivot = per_rep_mean.pivot_table(index=group_cols, columns="rep", values="value")
    rep_cols_sorted = sorted(pivot.columns, key=_rep_sort_key)
    pivot = pivot[rep_cols_sorted]

    row_mean = pivot.mean(axis=1)
    row_std = pivot.std(axis=1, ddof=1)
    row_count = pivot.count(axis=1)
    row_cov = 100 * row_std / row_mean

    pivot = pivot.rename(columns=lambda r: f"Rep {r} Mean (ms)").round(3)
    pivot["Mean of Reps (ms)"] = row_mean.round(3)
    # Not fillna(0.0): a single repetition has no between-run SD, and 0.0 would misread as
    # perfect consistency rather than "not estimable".
    pivot["StdDev Across Reps (ms)"] = row_std.round(3)
    pivot["Independent Runs"] = row_count.astype(int)
    pivot["CoV Across Reps (%)"] = row_cov.round(2)

    pivot = pivot.reset_index()
    pivot.insert(0, "Group", pivot[group_cols].apply(lambda row: label_fn(tuple(row)), axis=1))
    pivot = pivot.drop(columns=group_cols)
    return pivot


# Output helpers

def _latex_text(text):
    """Escapes the LaTeX specials a caption can contain, leaving already-escaped ones."""
    return re.sub(r"(?<!\\)([%_&#])", r"\\\1", text)


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

    with open(tex_path, "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n")
        # Caption precedes the tabular body so it renders above the table,
        # matching Elsevier/JSS style.
        if caption:
            f.write(f"\\caption{{{_latex_text(caption)}}}\n")
        if label:
            f.write(f"\\label{{{label}}}\n")
        f.write(df.to_latex(index=False, escape=True))
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

# warmup_<pass>_rep<N>.json[.gz]; pass is baseline, scan or scan_maxvus.
WARMUP_FILE_RE = re.compile(r"^warmup_(?P<pass>[a-z_]+?)_rep(?P<rep>\d+)\.json(?:\.gz)?$")


def read_run_metadata(results_dir, name="run_metadata.json"):
    """The run's own metadata, or {} when absent or unreadable."""
    path = os.path.join(results_dir, name)
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"[!] {name} could not be read ({e}); falling back to defaults where it is consulted.")
        return {}


def analyze_warmup(results_dir, output_dir, metadata=None):
    """Table 0: per warm-up pass and target, whether latency had converged when the
    measured phase began.

    Streams the warmup_* files through the gate itself rather than loading them
    with load_results(): the verdict depends on the contiguous, time-ordered tail,
    which reservoir subsampling would break. Every target in the run's TARGETS gets
    a row even when it never produced three windows.
    """
    suite = (metadata or {}).get("suite_config", {})
    params = warmup_check.gate_params(suite.get("warmup_gate"))
    expect = [str(t) for t in suite.get("targets", [])]

    files = []
    for fp in glob.glob(os.path.join(results_dir, "warmup_*.json*")):
        m = WARMUP_FILE_RE.match(os.path.basename(fp))
        if m:
            # Chronological: every baseline rep, then each scan rep's two passes.
            files.append((m.group("pass") != "baseline", int(m.group("rep")), m.group("pass"), fp))
    if not files:
        print("[!] No warmup_* files found; skipping the warm-up convergence check.")
        return None

    rows = []
    for *_, fp in sorted(files):
        name = os.path.basename(fp)
        file_rows, truncated = warmup_check.file_rows(fp, expect, params, _tier_label)
        if truncated:
            print(f"[!] {name}: compressed stream ended early; judged on what decompressed cleanly.")
        rows.extend({"Source File": name, **r} for r in file_rows)

    table = pd.DataFrame(rows)
    save_table(table, "table0_warmup_convergence_check", output_dir,
               caption=warmup_check.caption(params, "Per-rep, per-target"),
               label="tab:warmup-convergence")
    if warmup_check.report(table, params, "warm-up target(s)", ["Source File"]):
        print("    Raise MAX_WARMUP_CHUNKS or WARMUP_CHUNK_DURATION_S before trusting those "
              "targets' measured phase.")
    return table


def analyze_measurement_floor(e2e, order, output_dir, floor_tier="calibration",
                              exempt=("mock",)):
    """Counts model-inference requests that completed faster than the zero-work
    calibration floor.

    The calibration target does no business logic, so its fastest request bounds
    what the transport and framework can physically achieve, and a model-inference
    request below it is a timing artifact rather than a fast inference. mock is
    exempt: it adds only a random draw to calibration's path, so the two
    distributions coincide and about half of mock's fastest requests fall below
    calibration's single fastest one by sampling alone.
    """
    if floor_tier not in order:
        print(f"[!] No '{floor_tier}' target in this run; skipping measurement-floor check.")
        return

    floor_vals = e2e[e2e["tier"] == floor_tier]["value"]
    if floor_vals.empty:
        print(f"[!] '{floor_tier}' target present but has no valid values; "
              f"skipping measurement-floor check.")
        return
    floor = float(floor_vals.min())

    rows = []
    for t in order:
        if t == floor_tier or t in exempt:
            continue
        vals = e2e[e2e["tier"] == t]["value"]
        if vals.empty:
            continue
        below = vals[vals < floor]
        rows.append({
            "Group": _tier_label(t),
            "N": len(vals),
            "Min (ms)": round(float(vals.min()), 3),
            "Below floor (n)": len(below),
            "Below floor (%)": round(100 * len(below) / len(vals), 3),
            "Lowest below floor (ms)": round(float(below.min()), 3) if len(below) else np.nan,
        })
    if not rows:
        print("[!] No model-inference tier in the baseline data; skipping measurement-floor check.")
        return

    table = pd.DataFrame(rows)
    save_table(table, "table1e_measurement_floor_violations", output_dir,
               caption=f"Model-inference requests completing faster than the zero-work calibration "
                       f"floor ({floor:.3f} ms, the fastest observed '{floor_tier}' request). The floor "
                       f"is the physical lower bound for the transport and framework, so a request "
                       f"below it is a timing artifact rather than a fast inference, and a non-zero "
                       f"count identifies a tier whose reported minimum should not be read as a real "
                       f"latency. mock is not listed: it adds only a random draw to the calibration "
                       f"path, so its fastest requests fall below the floor by sampling alone.",
               label="tab:measurement-floor")

    total_below = int(table["Below floor (n)"].sum())
    if total_below:
        print(f"[!] {total_below} model-inference request(s) completed below the {floor:.3f} ms "
              f"calibration floor -- see table1e; treat the affected tiers' reported minima as "
              f"artifacts.")


# baseline decomposition (VUS=1)

def analyze_baseline(df, output_dir, true_counts=None):
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
    if n_reps < 2:
        print(f"[!] Only {n_reps} repetition detected. Table 1's Mean/P95 95% CI columns read as "
              f"'[nan, nan]', Table 1b's between-run consistency is not estimable, and Table 5's "
              f"significance test is skipped entirely (both sides need >=2 reps).")

    # Latency computed on successful (200) requests only; see Table 1c for error rates
    e2e = base[(base["metric"] == "http_req_duration") & base["value"].notna() & (base["status"] == "200")]

    # Table 1: pooled within-run end-to-end latency per target (all reps combined, successful requests only)
    rows = [summarize(e2e[e2e["tier"] == t], _tier_label(t), true_counts=true_counts,
                      metric="http_req_duration", phase="baseline", status="200", tier=t)
            for t in order]
    table1 = pd.DataFrame([r for r in rows if r])
    save_table(table1, "table1_baseline_e2e_latency_pooled", output_dir,
               caption="End-to-end request latency by strategy/tier at VUS=1, pooled across all repetitions, "
                       "computed over successful (HTTP 200) requests only (within-run bootstrap CIs; see Table 1b "
                       "for between-run reproducibility and Table 1c for the error rate this excludes).",
               label="tab:baseline-e2e-pooled")

    # Table 1c: error/timeout breakdown per target
    table1c = error_summary(base, "baseline", ["tier"], lambda k: _tier_label(k[0]), true_counts=true_counts)
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


    decomp_rows = []
    for t in order:
        row = {"Group": _tier_label(t)}
        for metric in PYTHON_TELEMETRY_METRICS:
            vals = base[(base["metric"] == metric) & (base["tier"] == t)]["value"]
            row[metric] = round(float(vals.mean()), 3) if not vals.empty else np.nan
        # The serialization figure is an EWMA estimate folded into the total it
        # helps compute, so its share bounds how much that circularity can matter.
        serial_mean = row.get("python_serialization_time_ms", np.nan)
        total_mean = row.get("python_total_time_ms", np.nan)
        row["Serialization (% of total)"] = (
            round(100 * serial_mean / total_mean, 2)
            if total_mean and not np.isnan(serial_mean) and not np.isnan(total_mean) else np.nan
        )
        net_vals = base[(base["metric"] == JAVA_BRIDGE_OVERHEAD_METRIC) & (base["tier"] == t)]["value"]
        row[JAVA_BRIDGE_OVERHEAD_METRIC] = round(float(net_vals.mean()), 3) if not net_vals.empty else np.nan
        row["Negative (%)"] = round(100 * float((net_vals < 0).mean()), 1) if not net_vals.empty else np.nan
        row["Min (ms)"] = round(float(net_vals.min()), 3) if not net_vals.empty else np.nan
        decomp_rows.append(row)
    table2 = pd.DataFrame(decomp_rows)
    save_table(table2, "table2_baseline_python_decomposition_mean_ms", output_dir,
               caption="Mean Python-side latency decomposition (ms) by tier at VUS=1, pooled across "
                       "repetitions, with the estimated bridge overhead (round-trip time minus "
                       "Python execution time; Docker bridge-network and framework overhead, not a "
                       "real network hop) shown alongside. 'Serialization (\\% of total)' bounds "
                       "the self-referential serialization estimate's contribution to the total it is "
                       "folded into. 'Negative (\\%)' and 'Min (ms)' quantify "
                       "how often and how far that column goes negative per tier -- a small, tier-"
                       "consistent rate reflects clock/timer noise between the two processes; a large "
                       "or tier-clustered rate would indicate a real measurement problem, not noise.",
               label="tab:baseline-decomp")

    analyze_measurement_floor(e2e, order, output_dir)

    # Table 3: cost of building the DataFrame, as a share of measured computation.
    share_rows = []
    for t in order:
        if t in ("mock", "calibration"):
            continue
        df_t = base[(base["metric"] == "python_dataframe_construction_time_ms") & (base["tier"] == t)]["value"]
        inf_t = base[(base["metric"] == "python_model_inference_time_ms") & (base["tier"] == t)]["value"]
        comp_t = base[(base["metric"] == "python_computation_time_ms") & (base["tier"] == t)]["value"]
        if df_t.empty or inf_t.empty or comp_t.empty:
            continue
        comp_mean = float(comp_t.mean())
        share_rows.append({
            "Tier": _tier_label(t),
            "Mean pd.DataFrame() Construction (ms)": round(float(df_t.mean()), 3),
            "Mean predict_proba() Call (ms)": round(float(inf_t.mean()), 3),
            "Mean Computation Total (ms)": round(comp_mean, 3),
            "pd.DataFrame() Construction Share of Computation (%)":
                round(100 * float(df_t.mean()) / comp_mean, 1) if comp_mean else np.nan,
        })
    table3 = pd.DataFrame(share_rows)
    save_table(table3, "table3_dataframe_share_of_computation", output_dir,
               caption="Cost of constructing the single-row pandas DataFrame, as a share of total "
                       "measured computation time, by tier (pooled across all repetitions). This "
                       "column covers the \\texttt{pd.DataFrame()} call only. The larger "
                       "pandas-related cost -- XGBoost's conversion of that DataFrame into its "
                       "internal DMatrix representation -- occurs inside \\texttt{predict\\_proba} "
                       "and is therefore counted in the \\texttt{predict\\_proba()} column, not here.",
               label="tab:df-share")

    # Runs on e2e (status==200 only): an error or timeout response has a latency that
    # reflects the failure path, not the tier's inference cost.
    table5 = pairwise_mannwhitney(e2e, "http_req_duration", "baseline", "tier", order, _tier_label)
    save_table(table5, "table5_baseline_adjacent_tier_significance", output_dir,
               caption="Mann-Whitney U test between adjacent feature-count tiers, end-to-end latency "
                       "at VUS=1. Tested on rep-level means (one independent observation per repetition) "
                       "to avoid pseudoreplication from correlated within-run requests; Holm-Bonferroni "
                       "corrected across the tier-comparison family. Rank-biserial effect size reported "
                       "alongside significance. Pooled-request p-value included for reference only.",
               label="tab:baseline-mannwhitney")

    # Figure 1: stacked bar of Python-side decomposition, AI tiers only.
    # computeStallMs is deliberately absent: it is the off-CPU portion of the
    # computation window, so it is already inside the DataFrame-construction and
    # predict_proba wall clocks and stacking it would count that time twice.
    ai_order = [t for t in order if t not in ("mock", "calibration")]
    if ai_order:
        stages = [
            ("python_parsing_time_ms", "Request Parsing"),
            ("python_thread_dispatch_time_ms", "Thread Dispatch"),
            ("python_dataframe_construction_time_ms", "DataFrame Construction"),
            ("python_model_inference_time_ms", "predict_proba() Call"),
            ("python_serialization_time_ms", "Response Serialization"),
        ]
        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(ai_order))
        x_labels = [f"v{t}" for t in ai_order]
        for i, (metric, label) in enumerate(stages):
            vals = np.array([
                base[(base["metric"] == metric) & (base["tier"] == t)]["value"].mean()
                for t in ai_order
            ])
            vals = np.nan_to_num(vals)
            ax.bar(x_labels, vals, bottom=bottoms, label=label,
                   color=COLOR_CYCLE[i % len(COLOR_CYCLE)], edgecolor="black", linewidth=0.5)
            bottoms += vals

        # Residual against the measured total, so the bars sum to what Python reported
        # rather than to the sum of the stages that happen to be instrumented.
        totals = np.nan_to_num(np.array([
            base[(base["metric"] == "python_total_time_ms") & (base["tier"] == t)]["value"].mean()
            for t in ai_order
        ]))
        ax.bar(x_labels, np.maximum(totals - bottoms, 0), bottom=bottoms, label="Other (unattributed)",
               color="#95a5a6", edgecolor="black", linewidth=0.5)

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
    per_rep = e2e.groupby(["tier", "rep"], observed=True)["value"].mean().reset_index()
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

def _scan_sampling_regime(vus, calib_cfg):
    """'Iteration-based' vs. 'Duration-calibrated' label for one scan VUS level, read from
    the run's own suite_config.calibration (run_metadata.json) rather than a hardcoded
    level list that could drift from what run-suite.sh actually used. The two regimes are
    why Table 4's N differs by orders of magnitude between rows instead of scaling with
    VUS: affected levels run to a fixed wall-clock target instead of a fixed per-VU
    iteration count.
    """
    affected = calib_cfg.get("affected_levels")
    if affected is None:
        return "unknown (run_metadata.json not available)"
    if int(vus) in {int(v) for v in affected}:
        duration = calib_cfg.get("target_duration_s")
        return f"Duration-calibrated (~{int(duration)}s)" if duration else "Duration-calibrated"
    return "Iteration-based"


def analyze_scan(df, output_dir, true_counts=None, metadata=None):
    scan = df[df["phase"] == "scan"]
    if scan.empty:
        print("[!] No phase='scan' data found; skipping E2 analysis.")
        return

    order = [t for t in TIER_ORDER if t in scan["tier"].unique()]
    seen_levels = sorted(int(v) for v in scan["vus"].dropna().unique())
    # Canonical levels first, then anything else the run used, so a CONCURRENCY_OVERRIDE
    # containing non-default values cannot silently drop those cells from every table.
    levels = ([v for v in CONCURRENCY_ORDER if v in seen_levels]
              + [v for v in seen_levels if v not in CONCURRENCY_ORDER])
    if not order or not levels:
        print("[!] No recognized tiers/concurrency levels in scan data; skipping E2 analysis.")
        return

    n_reps = scan["rep"].nunique()
    print(f"[*] E2 scan: {n_reps} independent repetition(s) detected.")
    if n_reps < 2:
        print(f"[!] Only {n_reps} repetition detected. Table 4's Mean/P95 95% CI columns read as "
              f"'[nan, nan]', Table 4b's between-run consistency is not estimable, and Table 6's "
              f"significance test is skipped entirely (both sides need >=2 reps).")

    calib_cfg = (metadata or {}).get("suite_config", {}).get("calibration", {})

    # Latency computed on successful (200) requests only; see Table 4c for error rates
    e2e = scan[(scan["metric"] == "http_req_duration") & scan["value"].notna() & (scan["status"] == "200")]

    # Table 4c: error/timeout breakdown per (tier, concurrency) cell;
    # reused for the "Error Rate (%)" column in Table 4 below.
    table4c = error_summary(scan, "scan", ["tier", "vus"],
                            lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}", true_counts=true_counts)
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
            true_filters = dict(metric="http_req_duration", phase="scan", status="200", tier=t, vus=vus)
            s = summarize(cell, f"{_tier_label(t)} @ VUS={vus}", true_counts=true_counts, **true_filters)
            if not s:
                continue
            group_label = f"{_tier_label(t)} @ VUS={vus}"
            # NaN rather than 0.0: a missing lookup means the two tables disagree
            # about which cells exist, which should be visible, not read as "no errors".
            error_rate = error_rate_lookup.get(group_label, np.nan)
            throughput = _throughput_reqs_per_s(cell, true_counts=true_counts, **true_filters)
            per_rep_throughput = [_throughput_reqs_per_s(g, true_counts=true_counts, **true_filters)
                                  for _, g in cell.groupby("rep", observed=True)]
            per_rep_throughput = [v for v in per_rep_throughput if not np.isnan(v)]
            throughput_sd = (float(np.std(per_rep_throughput, ddof=1))
                             if len(per_rep_throughput) > 1 else 0.0)
            rows.append({
                "Tier": _tier_label(t),
                "Concurrency (VUS)": vus,
                "Sampling": _scan_sampling_regime(vus, calib_cfg),
                **s,
                "Throughput (req/s)": round(throughput, 2) if not np.isnan(throughput) else np.nan,
                "Throughput SD across reps (req/s)": round(throughput_sd, 2),
                "Error Rate (%)": error_rate,
            })
    table4 = pd.DataFrame(rows)
    save_table(table4, "table4_concurrency_scan_summary_pooled", output_dir,
               caption="Latency (successful requests only), throughput, and error rate across the "
                       "concurrency sweep, by tier. Latency percentiles pool all repetitions; "
                       "throughput is measured within each repetition and then averaged, since a "
                       "pooled span would include the restarts and cooldowns between repetitions. "
                       "The 'Sampling' column marks each row's sample-size regime: "
                       "'Iteration-based' levels run a fixed request count per virtual user, while "
                       "'Duration-calibrated' levels are calibrated to run for a fixed wall-clock "
                       "duration per cell instead -- which is why N can differ by orders of "
                       "magnitude between the two regimes rather than scaling with VUS. See Table "
                       "4b for between-run reproducibility and Table 4c for the full error/timeout "
                       "breakdown.",
               label="tab:scan-summary-pooled")

    # Table 4b: between-run consistency per (tier, concurrency) cell.
    # Uses e2e (status==200 only), matching Table 4 -- see Table 5 comment.
    table4b = between_run_consistency(e2e, "http_req_duration", "scan", ["tier", "vus"],
                                      lambda k: f"{_tier_label(k[0])} @ VUS={int(k[1])}")
    save_table(table4b, "table4b_scan_between_run_consistency", output_dir,
               caption="Between-run consistency of mean end-to-end latency across independent, "
                       "clean-slate repetitions of the concurrency scan.",
               label="tab:scan-between-run")

    # Table 4e: latency drift inside each cell, which a cell mean would otherwise hide.
    drift_groups = [(f"{_tier_label(t)} @ VUS={vus}", e2e[(e2e["tier"] == t) & (e2e["vus"] == vus)])
                    for t in order for vus in levels]
    table4e = thermal.within_cell_drift([(label, g) for label, g in drift_groups if not g.empty])
    save_table(table4e, "table4e_scan_within_cell_drift", output_dir,
               caption="Change in mean end-to-end latency from the first to the second half of each "
                       "scan cell, in time, averaged over repetitions with a t-interval across them. A "
                       "change of the same sign in every repetition is systematic -- heat soak, queue "
                       "build-up, or the closed-loop taper as VUs finish -- and means the cell mean "
                       "depends on the cell's duration, which calibration holds near the same target "
                       "for every cell at the calibrated levels.",
               label="tab:scan-within-cell-drift")

    # Table 6: significance between adjacent concurrency levels, per tier, on e2e
    # (status==200 only) -- a concurrency-driven failure's latency reflects the failure
    # path, not the tier's cost at that level. Holm is applied within each tier's family,
    # so one call per tier rather than one over the whole grid.
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
            per_rep_p95 = cell.groupby("rep", observed=True)["value"].apply(lambda s: np.percentile(s, 95))
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
            th = _throughput_reqs_per_s(cell, true_counts=true_counts, metric="http_req_duration",
                                        phase="scan", status="200", tier=t, vus=vus)
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

    # Figure 5: compute decomposition under load, one figure per real feature tier --
    # mock/calibration have no predict_proba() cost to decompose. Isolates thread-pool
    # queueing (Thread Dispatch) from the invariant steps (DataFrame construction, predict_proba).
    # Compute stall is drawn as an overlaid line rather than a stacked segment: it is the
    # off-CPU portion of the computation window, already inside the two wall clocks below it.
    stages = [
        ("python_thread_dispatch_time_ms", "Thread Dispatch"),
        ("python_dataframe_construction_time_ms", "DataFrame Construction"),
        ("python_model_inference_time_ms", "predict_proba() Call"),
    ]
    for tier in (t for t in order if t not in ("mock", "calibration")):
        def _stage_means(metric, tier=tier):
            return np.nan_to_num(np.array([
                scan[(scan["metric"] == metric) & (scan["tier"] == tier) & (scan["vus"] == vus)]["value"].mean()
                for vus in levels
            ]))

        fig, ax = plt.subplots(figsize=(7, 4.5), dpi=300)
        bottoms = np.zeros(len(levels))
        x_labels = [str(v) for v in levels]
        for i, (metric, label) in enumerate(stages):
            vals = _stage_means(metric)
            ax.bar(x_labels, vals, bottom=bottoms, label=label,
                   color=COLOR_CYCLE[i % len(COLOR_CYCLE)], edgecolor="black", linewidth=0.5)
            bottoms += vals

        stall = _stage_means("python_compute_stall_time_ms")
        ax.plot(x_labels, stall, marker="o", linestyle="--", linewidth=1.6, color="#c0392b",
                label="GIL/Scheduling Stall (subset of Thread Dispatch, off-CPU)")

        ax.set_xlabel("Concurrency (VUs)")
        ax.set_ylabel("Mean Latency (ms)")
        ax.set_title(f"Compute Decomposition vs. Concurrency (Tier v{tier}, pooled)", fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(True, axis="y", linestyle="--", alpha=0.4)
        save_figure(fig, f"figure5_decomposition_vs_concurrency_v{tier}", output_dir)



GC_LINE_RE = re.compile(
    r"^\[(?P<wall>[^\]]+)\]\[(?P<uptime>[\d.]+)s\]\[(?P<level>[a-z]+)\s*\]\[(?P<tags>[^\]]+?)\s*\]\s*(?P<msg>.*)$"
)
GC_DUR_RE = re.compile(r"(?P<dur_ms>[\d.]+)ms\s*$")
# Unified Logging prefixes each pause record with its cycle number: "GC(N) Pause ...",
# so the message never begins with "Pause" itself.
GC_PAUSE_RE = re.compile(r"^GC\(\d+\)\s+Pause")
# Matches the JVM's one-line startup log, e.g. "Using G1".
GC_COLLECTOR_RE = re.compile(r"^Using (?P<collector>\S.*)$")


def _gc_wall_clock(stamp):
    try:
        return datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        return None


def parse_gc_log(path):
    """Extracts (uptime_s, pause_ms) for each pause event, plus the collector that produced them.

    Returns (pauses, window_s, collector). The log holds two JVMs: every probe JVM the
    rep's pin checks start in the same container reopens and truncates it, so it
    begins with the last probe's own startup lines (uptime near zero) and continues
    with the service JVM's records from that moment on (uptime since the service
    started). window_s is therefore the wall-clock span between the first and last
    record, not an uptime difference, which would add the service JVM's age at the
    last probe. `collector` comes from the probe's "Using <Collector>" record: same
    container, same JAVA_TOOL_OPTIONS, so the same collector the service JVM runs.
    None if that record is absent.
    """
    pauses = []
    first_wall = last_wall = None
    first_uptime = last_uptime = None
    n_lines = 0
    collector = None
    with open(path, errors="replace") as f:
        for line in f:
            m = GC_LINE_RE.match(line)
            if not m:
                continue
            n_lines += 1
            uptime = float(m.group("uptime"))
            first_uptime = first_uptime if first_uptime is not None else uptime
            last_uptime = uptime
            wall = _gc_wall_clock(m.group("wall"))
            if wall is not None:
                first_wall = first_wall or wall
                last_wall = wall
            if m.group("level") != "info" or m.group("tags") != "gc":
                continue
            msg = m.group("msg")
            cm = GC_COLLECTOR_RE.match(msg)
            if cm:
                collector = cm.group("collector").strip()
                continue
            if not GC_PAUSE_RE.match(msg):
                continue
            dm = GC_DUR_RE.search(msg)
            if dm:
                pauses.append((uptime, float(dm.group("dur_ms"))))

    # Checked even when pauses were parsed: GC_PAUSE_RE matches Unified Logging's generic
    # "GC(N) Pause ..." record, so Serial, Parallel and Shenandoah parse through it too,
    # differing from G1 only in the parenthetical cause. Only ZGC's format does not match,
    # which means a successful parse is not by itself evidence that G1 produced the data.
    if collector is not None and collector != "G1":
        print(f"[gc] WARNING: {os.path.basename(path)} selected '{collector}', not G1. "
              f"{len(pauses)} pause event(s) parsed from this log are that collector's, and are "
              f"not comparable to G1 pause data -- treat this rep's GC overhead as unmeasured "
              f"rather than as G1's. Check mem_limit/cpus have not dropped below HotSpot's "
              f"server-class threshold, which silently changes the collector.")
    elif n_lines and not pauses:
        if collector == "G1":
            print(f"[gc] {os.path.basename(path)}: G1 confirmed selected (startup log), "
                  f"but 0 pause events in this rep's {n_lines}-line window -- read as "
                  f"'no GC cycle ran' (e.g. light load), not as unmeasured overhead.")
        else:
            print(f"[gc] WARNING: {os.path.basename(path)} has {n_lines} parsable lines but no "
                  f"pause events, and no 'Using <Collector>' startup line was found either. "
                  f"Collector identity unknown; GC overhead is unmeasured for this rep, not zero.")

    if first_wall is not None:
        window_s = (last_wall - first_wall).total_seconds()
    else:
        # A log without the time decorator can only be spanned by uptime.
        window_s = (last_uptime - first_uptime) if first_uptime is not None else None
    return pauses, window_s, collector


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
        pauses, window_s, collector = parse_gc_log(log_path)
        total_ms = sum(d for _, d in pauses)
        max_ms = max((d for _, d in pauses), default=0.0)
        overhead_pct = (total_ms / 1000.0 / window_s * 100.0) if window_s else None
        rows.append({
            "phase": phase, "rep": rep, "collector": collector or "unknown",
            "n_pauses": len(pauses),
            "total_pause_ms": round(total_ms, 2), "max_pause_ms": round(max_ms, 2),
            "window_s": round(window_s, 1) if window_s else None,
            "gc_overhead_pct": round(overhead_pct, 3) if overhead_pct is not None else None,
        })

    if not rows:
        print("[gc] gc-logs directory exists but no gc_<phase>_rep<N>.log files found -- skipping.")
        return

    gc_df = pd.DataFrame(rows).sort_values(["phase", "rep"])
    save_table(gc_df, "table_gc_overhead", output_dir,
               caption="Per-repetition JVM GC pause overhead (Unified JVM Logging, -Xlog:gc*). "
                       "The 'collector' column is read from each log's own \"Using <Collector>\" "
                       "startup record: pause records are only comparable across rows reporting the "
                       "same collector, and a non-G1 row means that rep's GC overhead is unmeasured "
                       "rather than measured-as-zero.",
               label="tab:gc-overhead")

    # gc_overhead_pct is NaN when the log had no parsable "Using <Collector>"/uptime
    # records (e.g. zero parsable lines) -- those rows fail the ">1.0" comparison
    # silently and would otherwise be counted as passing rather than unmeasured.
    unmeasured = gc_df[gc_df["gc_overhead_pct"].isna()]
    if not unmeasured.empty:
        print(f"[gc] WARNING: {len(unmeasured)} rep(s) have no measurable GC overhead "
              f"(log had no parsable pause/uptime records) -- see table_gc_overhead; "
              f"not included in the overhead check below.")

    high = gc_df[gc_df["gc_overhead_pct"] > 1.0]
    if not high.empty:
        print(f"[gc] WARNING: {len(high)} rep(s) show >1% of wall-clock time in GC pauses -- "
              f"see table_gc_overhead; GC may be contributing to tail latency.")
    elif unmeasured.empty:
        print("[gc] GC pause overhead <=1% of wall-clock time in all reps.")

    fig, ax = plt.subplots(figsize=(8, 4))
    for phase, g in gc_df.groupby("phase", observed=True):
        ax.bar([f"{phase} r{r}" for r in g["rep"]], g["gc_overhead_pct"].fillna(0), label=phase)
    ax.set_ylabel("GC pause overhead (% of wall-clock time)")
    ax.set_title("Per-repetition JVM GC overhead")
    ax.legend()
    plt.xticks(rotation=45, ha="right")
    save_figure(fig, "fig_gc_overhead", output_dir)


# thermal state per cell

# Each measured cell's name in the env trace: its result file's stem.
CELL_NAME_RE = re.compile(r"^(?P<phase>baseline|scan)_(?P<tier>[a-z0-9]+?)(?:_vus(?P<vus>\d+))?_rep(?P<rep>\d+)$")
# (service, run_metadata.json cores_used_by_suite key) for the throttle attribution.
SUITE_SERVICES = (("python", "python_service_cpuset"), ("java", "transaction_service_cpuset"),
                  ("k6", "k6_cpuset"))


def _suite_phase(name):
    """Run phase of a trace line's name: an env-sample label, a cell or a thermal-check label."""
    name = str(name or "")
    if name.startswith(("calib_warmup", "scan calibration", "scan_calibration")):
        return "scan calibration pass"
    if name.startswith("warmup_baseline"):
        return "baseline warm-up"
    if name.startswith("warmup_scan"):
        return "scan warm-up"
    if name.startswith(("baseline ", "baseline_")):
        return "baseline cells"
    if name.startswith(("scan ", "scan_")):
        return "scan cells"
    return "other"


def _cell_tier_group(cell):
    """(phase, tier) of a measured cell's trace name, or None for anything else."""
    m = CELL_NAME_RE.match(str(cell))
    return (m.group("phase"), m.group("tier")) if m else None


def _tier_group_label(group):
    return f"{group[0]} {_tier_label(group[1])}"


def _tier_group_order(group):
    phase, tier = group
    return (phase != "baseline", TIER_ORDER.index(tier) if tier in TIER_ORDER else len(TIER_ORDER), tier)


def cell_mean_latency(df, phase):
    """Mean HTTP 200 latency per measured cell, keyed by the cell's trace name, with
    the design cell (tier, plus VUS for the scan) it repeats as its group."""
    e2e = df[(df["phase"] == phase) & (df["metric"] == "http_req_duration") & (df["status"] == "200")]
    rows = []
    for source, mean in e2e.groupby("source_file", observed=True)["value"].mean().items():
        cell = re.sub(r"\.json(?:\.gz)?$", "", str(source))
        m = CELL_NAME_RE.match(cell)
        if m and m.group("phase") == phase and pd.notna(mean):
            group = m.group("tier") + (f"@{m.group('vus')}" if m.group("vus") else "")
            rows.append({"cell": cell, "group": group, "mean_ms": float(mean)})
    return pd.DataFrame(rows)


def analyze_thermal(results_dir, output_dir, metadata, latency):
    """Tables 8a-8c and figure 8: host temperature and thermal throttling per measured
    cell, the time thermal pauses cost, and whether either tracks a cell's latency."""
    path = os.path.join(results_dir, "env_trace_log.txt")
    if not os.path.isfile(path):
        print("[thermal] No env_trace_log.txt found -- skipping thermal analysis.")
        return
    trace = thermal.parse_env_trace(path)
    cores = (metadata or {}).get("cores_used_by_suite", {})
    cpusets = {svc: cores[key] for svc, key in SUITE_SERVICES if cores.get(key) not in (None, "", "unknown")}
    cells = thermal.cell_thermal(trace, lambda cell: cpusets)
    if cells.empty:
        print("[thermal] env_trace_log.txt has no per-cell samples -- skipping thermal analysis.")
        return

    save_table(thermal.thermal_by_group(cells, _cell_tier_group, list(cpusets),
                                        label_of=_tier_group_label, sort_key=_tier_group_order),
               "table8a_thermal_by_group", output_dir,
               caption="Highest thermal-zone temperature at the start and end of each measured cell, "
                       "and the thermal throttling accrued during it (Intel therm_throt counters, "
                       "differenced across the cell), per phase and tier. A service's core throttle is "
                       "the most-throttled CPU in its cpuset; 'not exposed' means the host does not "
                       "publish the counters, so throttling is unmeasured rather than absent.",
               label="tab:thermal-by-group")
    save_table(thermal.thermal_pauses(trace, _suite_phase), "table8b_thermal_pauses", output_dir,
               caption="Thermal safety checks per run phase: how many paused the run to let the host "
                       "cool, and the wall-clock time those pauses cost.",
               label="tab:thermal-pauses")

    parts = []
    for phase in ("baseline", "scan"):
        lat = latency[latency["cell"].str.startswith(f"{phase}_")] if latency is not None and not latency.empty \
            else pd.DataFrame()
        part = thermal.thermal_latency_association(cells, lat)
        if not part.empty:
            part.insert(0, "Phase", phase)
            parts.append(part)
    save_table(pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(),
               "table8c_thermal_latency_association", output_dir,
               caption="Spearman correlation between a cell's thermal state and its mean latency, "
                       "taken as its percent deviation from its design cell's mean across "
                       "repetitions, so the latency differences the design manipulates do not "
                       "register as a thermal effect. A near-zero correlation means temperature and "
                       "throttling do not explain the between-repetition spread.",
               label="tab:thermal-latency")

    throttle_cols = [c for c in cells.columns if c.endswith("_throttle_ms") and c != "pkg_throttle_ms"]
    throttled = cells[cells[throttle_cols].fillna(0).gt(0).any(axis=1)] if throttle_cols else cells.iloc[0:0]
    if not throttled.empty:
        print(f"[thermal] WARNING: {len(throttled)}/{len(cells)} measured cell(s) were thermally throttled "
              f"on a service's cores -- see table8a/table8c before attributing their latency to the "
              f"condition under test: {', '.join(throttled['cell'].head(10))}"
              f"{' ...' if len(throttled) > 10 else ''}")
    elif throttle_cols and cells[throttle_cols].notna().any().any():
        print(f"[thermal] No measured cell was throttled on a service's cores ({len(cells)} cells).")

    fig = thermal.timeline_figure(trace, _suite_phase, "Host temperature across the run")
    if fig is not None:
        save_figure(fig, "figure8_thermal_timeline", output_dir)


def analyze_openloop_check(df, output_dir, true_counts=None):
    # Open-loop (constant-arrival-rate) cells are run manually, so this returns without a
    # table when none are present.
    #
    # run-smoke-test.sh's own open-loop cell (openloop_28_smoke.json) lands in this same
    # results dir at a deliberately unsustainable RATE=5000, to prove dropped_iterations
    # fires before trusting a real run. Excluded by phase=="smoke-openloop" (the tag
    # run-target-openloop.js sets from PHASE; a real manual check defaults to
    # "openloop-check") rather than by filename, so a leftover smoke artifact is never
    # reported as a real validity check.
    # Unfiltered by status: a cell so overloaded that nothing succeeded must still be
    # identifiable as a cell, or it and its dropped_iterations vanish from the table
    # entirely -- exactly the overload case this check exists to catch.
    ol_files_all = df[df["source_file"].str.startswith("openloop", na=False) &
                       (df["metric"] == "http_req_duration")]
    ol_all = ol_files_all[ol_files_all["status"] == "200"]
    ol = ol_all[ol_all["phase"] != "smoke-openloop"]

    n_smoke_pts = int((ol_all["phase"] == "smoke-openloop").sum())
    if n_smoke_pts:
        print(f"[!] table7: excluded {n_smoke_pts} smoke-test open-loop point(s) "
              f"(phase=smoke-openloop) -- that cell is a deliberate RATE overload to "
              f"prove dropped_iterations fires, not a real validity check.")

    # Checked against ol_files_all (any status), not ol (200-only): a run where every
    # open-loop cell was totally overloaded would otherwise look identical to no
    # open-loop data at all and skip the table instead of reporting the overload.
    if ol_files_all.empty:
        return

    dropped_all = df[df["source_file"].str.startswith("openloop", na=False) & (df["metric"] == "dropped_iterations")]

    # dropped_iterations lacks per-request tags (phase/rate/tier) as unexecuted
    # iterations miss http.post() entirely -- k6 only ever tags it with scenario="run".
    # Attributes drops via source_file (openloop_<tier>_*.json) using the tier/rate/phase
    # every http_req_duration point in that same file actually carries.
    file_meta = ol_files_all.groupby("source_file", observed=True)[["tier", "rate", "phase"]].first()
    dropped_by_file = dropped_all.groupby("source_file", observed=True)["value"].sum()

    # The two indexes are independent categoricals built from different subsets, so their
    # category sets (and code widths) need not agree. Plain strings give the reindex below
    # a well-defined label-to-label alignment.
    file_meta.index = file_meta.index.astype(str)
    dropped_by_file.index = dropped_by_file.index.astype(str)
    # A smoke file's dropped_iterations points carry no phase of their own (see above),
    # so they're excluded the same way file_meta's own phase says they should be.
    smoke_files = set(file_meta.index[file_meta["phase"] == "smoke-openloop"])

    # Cell universe comes from file_meta (any status), not ol (200-only), so a cell
    # with zero successful responses still gets a row instead of disappearing.
    cell_meta = file_meta[~file_meta.index.isin(smoke_files)]

    # Compare against the top of whatever concurrency sweep this run actually used, not a
    # hardcoded pair -- computed once (it does not depend on tier) so the caption below can
    # name the levels this run actually used rather than assuming the default sweep's top two.
    scan_levels = sorted(int(v) for v in df.loc[df["phase"] == "scan", "vus"].dropna().unique())
    top_levels = scan_levels[-2:]

    rows = []
    for tier in sorted(cell_meta["tier"].dropna().unique(), key=lambda t: TIER_ORDER.index(t) if t in TIER_ORDER else 99):
        # Grouping by rate too, not just tier: two open-loop files for the same tier at
        # different RATEs are two different checks, not one pooled sample -- pooling
        # them would silently average a sustainable rate together with an unsustainable
        # one instead of showing both.
        for rate in sorted(cell_meta.loc[cell_meta["tier"] == tier, "rate"].dropna().unique(), key=lambda r: float(r)):
            cell_files = cell_meta[(cell_meta["tier"] == tier) & (cell_meta["rate"] == rate)].index
            dropped_count = int(dropped_by_file.reindex(cell_files, fill_value=0).sum())
            ol_cell = ol[(ol["tier"] == tier) & (ol["rate"] == rate)]
            # rate, not phase: distinguishes cells the same way ol_cell itself was
            # filtered above, without assuming which phase value a manual check used.
            ol_stats = summarize(ol_cell, f"{_tier_label(tier)} open-loop rate={rate}",
                                 true_counts=true_counts, metric="http_req_duration",
                                 status="200", tier=tier, rate=rate)
            if not ol_stats:
                # No 200 responses at all: total overload. Reported anyway so the
                # dropped-iterations count -- the overload signal itself -- is not
                # silently omitted along with the missing latency stats.
                rows.append({"Tier": _tier_label(tier), "Model": f"Open-loop (rate={rate}/s)",
                             "P95 (ms)": np.nan, "P99 (ms)": np.nan, "N": 0,
                             "Dropped iterations": str(dropped_count)})
                continue
            rows.append({"Tier": _tier_label(tier), "Model": f"Open-loop (rate={rate}/s)",
                         "P95 (ms)": ol_stats["P95 (ms)"], "P99 (ms)": ol_stats["P99 (ms)"],
                         "N": ol_stats["N (pooled, all reps)"],
                         "Dropped iterations": str(dropped_count)})

        for vus in top_levels:
            cl_cell = df[(df["phase"] == "scan") & (df["metric"] == "http_req_duration") &
                         (df["status"] == "200") & (df["tier"] == tier) & (df["vus"] == vus)]
            cl_stats = summarize(cl_cell, f"{_tier_label(tier)} closed-loop VUS={vus}",
                                 true_counts=true_counts, metric="http_req_duration",
                                 phase="scan", status="200", tier=tier, vus=vus)
            if cl_stats:
                rows.append({"Tier": _tier_label(tier), "Model": f"Closed-loop VUS={vus}",
                             "P95 (ms)": cl_stats["P95 (ms)"], "P99 (ms)": cl_stats["P99 (ms)"],
                             "N": cl_stats["N (pooled, all reps)"],
                             # Written as a string, not "n/a": pandas reads that back as NaN.
                             "Dropped iterations": "not applicable"})

    if not rows:
        return

    table = pd.DataFrame(rows)
    # Named from top_levels itself, not the default sweep, so a CONCURRENCY_OVERRIDE run's
    # caption never claims levels this run didn't actually use.
    top_levels_str = "/".join(str(v) for v in top_levels) if top_levels else "n/a"
    save_table(table, "table7_openloop_validity_check", output_dir,
               caption=f"Open-loop (constant-arrival-rate) tail latency vs. the closed-loop scan at "
                       f"the top {len(top_levels)} concurrency level(s) this run's scan phase actually "
                       f"used (VUS {top_levels_str}), for manually-checked tiers. Validates the "
                       f"concurrency scan against coordinated omission; not part of the automated "
                       f"suite. Smoke-test artifacts (phase=smoke-openloop) are excluded regardless "
                       f"of how many are present.",
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

    metadata = read_run_metadata(args.results_dir)
    warmup_table = analyze_warmup(args.results_dir, args.output_dir, metadata)

    # Two passes, not one combined load: no analysis below needs baseline and
    # scan/openloop data at the same time, so only one of the two is ever resident.
    latency_parts = []
    df1, true1 = load_results(args.results_dir, prefixes=("baseline_",))
    df1_loaded = df1 is not None
    if df1 is None:
        print("[!] No baseline_* files found; skipping baseline analysis.")
    else:
        print(f"[*] Loaded {len(df1)} metric points (baseline) from {df1['source_file'].nunique()} file(s).")
        analyze_baseline(df1, args.output_dir, true_counts=true1)
        latency_parts.append(cell_mean_latency(df1, "baseline"))
    del df1, true1
    gc.collect()

    df2, true2 = load_results(args.results_dir, prefixes=("scan_", "openloop_"))
    df2_loaded = df2 is not None
    if df2 is None:
        print("[!] No scan_* files found; skipping concurrency-scan analysis.")
    else:
        print(f"[*] Loaded {len(df2)} metric points (scan+openloop) from {df2['source_file'].nunique()} file(s).")
        analyze_scan(df2, args.output_dir, true_counts=true2, metadata=metadata)
        analyze_openloop_check(df2, args.output_dir, true_counts=true2)
        latency_parts.append(cell_mean_latency(df2, "scan"))
    del df2, true2
    gc.collect()

    analyze_gc_logs(args.results_dir, args.output_dir)
    analyze_thermal(args.results_dir, args.output_dir, metadata,
                    pd.concat(latency_parts, ignore_index=True) if latency_parts else None)

    if not df1_loaded and not df2_loaded and warmup_table is None:
        print(f"[!] No warmup_*/baseline_*/scan_*/openloop_* files found in "
              f"{args.results_dir} -- nothing was analyzed.")
        sys.exit(1)

    print(f"\n[+] Done. Tables -> {os.path.join(args.output_dir, 'tables')}")
    print(f"[+] Done. Figures -> {os.path.join(args.output_dir, 'figures')}")


if __name__ == "__main__":
    main()