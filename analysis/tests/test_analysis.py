"""Guards the analysis helpers that shape every reported table and figure."""

import gzip
import importlib.util
import json
import subprocess
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ANALYSIS_DIR = Path(__file__).resolve().parents[1]
LOAD_TESTING_DIR = ANALYSIS_DIR.parent / "load-testing"


def _load(module_name, filename):
    """Imports a hyphenated script by path; neither is importable as a package."""
    spec = importlib.util.spec_from_file_location(module_name, ANALYSIS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


results = _load("analyze_results", "analyze-results.py")
ablation = _load("analyze_ablation", "analyze-ablation.py")
warmup_check = sys.modules["warmup_check"]
thermal = sys.modules["thermal"]


# run-ablation.sh cell values

def test_value_sort_key_orders_multirange_cpusets_by_core_count():
    """run-ablation.sh emits multi-range cpusets; single-range parsing raises on them."""
    values = ["0-1", "0-1,4-5,8-9", "0-1,4-5,8-9,12-13"]
    assert [ablation._value_sort_key(v) for v in values] == [2, 6, 8]
    assert sorted(values, key=ablation._value_sort_key) == values


def test_value_sort_key_orders_plain_numbers_numerically():
    assert sorted(["40", "64", "128"], key=ablation._value_sort_key) == ["40", "64", "128"]
    assert sorted(["1", "2", "3"], key=ablation._value_sort_key) == ["1", "2", "3"]


def test_cell_file_filter_rejects_warmup_and_metadata():
    assert ablation._is_cell_file("ablation_cpuset_0-1,4-5,8-9_rep3.json")
    assert ablation._is_cell_file("ablation_workers_token_matched_3_rep2.json")
    assert not ablation._is_cell_file("ablation_warmup_28_rep1.json")
    assert not ablation._is_cell_file("ablation_warmup_thread_limiter_40_rep1.json")
    assert not ablation._is_cell_file("ablation_run_metadata.json")


# labelling and ordering

def test_tier_label_keeps_untagged_rows_distinct_from_mock():
    assert results._tier_label("mock") == "mock"
    assert results._tier_label("calibration") == "calibration"
    assert results._tier_label("28") == "v28"
    assert results._tier_label(None) == "unknown"


def test_rep_sort_key_orders_numerically_not_lexically():
    assert sorted(["1", "10", "2"], key=results._rep_sort_key) == ["1", "2", "10"]


# effect size

# Cliff's delta convention: U is scipy's U for the FIRST sample, so U=0 (A entirely below B)
# is delta=-1.
@pytest.mark.parametrize("u_stat,expected", [(0, -1.0), (49, 1.0), (24.5, 0.0)])
def test_rank_biserial_spans_minus_one_to_one(u_stat, expected):
    assert results.rank_biserial_effect_size(u_stat, 7, 7) == pytest.approx(expected)


def test_both_scripts_agree_on_effect_size():
    assert (results.rank_biserial_effect_size(10, 7, 7)
            == ablation.rank_biserial_effect_size(10, 7, 7))


# cluster bootstrap

def test_cluster_bootstrap_needs_at_least_two_reps():
    one_rep = pd.DataFrame({"rep": ["1"] * 5, "value": [1.0, 2.0, 3.0, 4.0, 5.0]})
    assert all(np.isnan(x) for x in results.cluster_bootstrap_ci(one_rep, np.mean))


def test_cluster_bootstrap_brackets_the_point_estimate():
    df = pd.DataFrame({"rep": ["1"] * 50 + ["2"] * 50 + ["3"] * 50,
                       "value": [10.0] * 50 + [12.0] * 50 + [11.0] * 50})
    lo, hi = results.cluster_bootstrap_ci(df, np.mean)
    assert lo <= df["value"].mean() <= hi


def test_cluster_bootstrap_is_reproducible():
    df = pd.DataFrame({"rep": ["1"] * 20 + ["2"] * 20, "value": list(range(40))})
    assert results.cluster_bootstrap_ci(df, np.mean) == results.cluster_bootstrap_ci(df, np.mean)


# throughput

def _timed_cell(reps, n_per_rep, cell_span_s, gap_s):
    """Builds a cell whose reps each span cell_span_s and sit gap_s apart."""
    rows = []
    start = pd.Timestamp("2026-01-01T00:00:00Z")
    for rep in range(reps):
        rep_start = start + pd.Timedelta(seconds=rep * gap_s)
        for t in rep_start + pd.to_timedelta(np.linspace(0, cell_span_s, n_per_rep), unit="s"):
            rows.append({"rep": str(rep), "time": t})
    return pd.DataFrame(rows)


def test_throughput_is_measured_within_reps_not_across_them():
    """Pooling reps would put the restarts and cooldowns between them in the span."""
    cell = _timed_cell(reps=3, n_per_rep=100, cell_span_s=1.0, gap_s=3600)
    # 100 completions spanning exactly 1.0s bound 99 inter-completion intervals, so the
    # rate is 99/s. Asserted exactly, not with a loose tolerance.
    assert results._throughput_reqs_per_s(cell) == pytest.approx(99.0, rel=1e-9)


def test_throughput_is_unaffected_by_the_gap_between_reps():
    tight = _timed_cell(reps=3, n_per_rep=100, cell_span_s=1.0, gap_s=60)
    wide = _timed_cell(reps=3, n_per_rep=100, cell_span_s=1.0, gap_s=7200)
    assert results._throughput_reqs_per_s(tight) == pytest.approx(results._throughput_reqs_per_s(wide))


def test_throughput_is_nan_when_no_rep_has_two_timestamps():
    cell = pd.DataFrame({"rep": ["1", "2"], "time": pd.to_datetime(["2026-01-01T00:00:00Z"] * 2)})
    assert np.isnan(results._throughput_reqs_per_s(cell))


# scan level selection

def test_scan_tables_keep_non_default_concurrency_values(tmp_path):
    """A CONCURRENCY_OVERRIDE outside CONCURRENCY_ORDER must not drop those cells."""
    rows = []
    for vus in (2, 6, 12):
        for rep in ("1", "2"):
            for i in range(30):
                rows.append({"metric": "http_req_duration", "value": 5.0 + i % 3, "status": "200",
                             "phase": "scan", "tier": "28", "vus": float(vus), "rep": rep,
                             "source_file": f"scan_28_vus{vus}_rep{rep}.json.gz",
                             "time": pd.Timestamp("2026-01-01T00:00:00Z") + pd.Timedelta(milliseconds=10 * i)})
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path))
    table4 = pd.read_csv(tmp_path / "tables" / "table4_concurrency_scan_summary_pooled.csv")
    assert table4["Concurrency (VUS)"].tolist() == [2, 6, 12]
    drift = pd.read_csv(tmp_path / "tables" / "table4e_scan_within_cell_drift.csv")
    assert drift["Group"].tolist() == ["v28 @ VUS=2", "v28 @ VUS=6", "v28 @ VUS=12"]


# figure 5: compute decomposition per tier

def _decomposition_cell(tier, vus, rep, n=10):
    """One (tier, vus, rep) cell's http_req_duration rows plus its python_* stage means."""
    base = pd.Timestamp("2026-01-01T00:00:00Z") + pd.Timedelta(seconds=rep * 3600)
    source = f"scan_{tier}_vus{vus}_rep{rep}.json.gz"
    rows = [{"metric": "http_req_duration", "value": 5.0, "status": "200", "phase": "scan",
             "tier": tier, "vus": float(vus), "rep": str(rep), "source_file": source,
             "time": base + pd.Timedelta(milliseconds=10 * i)} for i in range(n)]
    for metric, value in (("python_thread_dispatch_time_ms", 0.2),
                          ("python_dataframe_construction_time_ms", 0.1),
                          ("python_model_inference_time_ms", 1.0),
                          ("python_compute_stall_time_ms", 0.3)):
        rows.append({"metric": metric, "value": value, "status": "200", "phase": "scan",
                     "tier": tier, "vus": float(vus), "rep": str(rep), "source_file": source, "time": base})
    return rows


def test_figure5_is_drawn_per_real_tier_not_only_the_heaviest(tmp_path):
    """mock/calibration have no predict_proba() cost to decompose; every feature tier gets its own figure."""
    rows = []
    for tier in ("5", "28", "mock"):
        for vus in (8, 16):
            for rep in (1, 2):
                rows += _decomposition_cell(tier, vus, rep)
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path))
    figures = {p.name for p in (tmp_path / "figures").glob("figure5_*.png")}
    assert figures == {"figure5_decomposition_vs_concurrency_v5.png",
                        "figure5_decomposition_vs_concurrency_v28.png"}


# table 4: sampling-regime column and low-rep warnings

def _scan_rows(tier, vus, rep, n=20):
    return [{"metric": "http_req_duration", "value": 5.0, "status": "200", "phase": "scan",
             "tier": tier, "vus": float(vus), "rep": str(rep),
             "source_file": f"scan_{tier}_vus{vus}_rep{rep}.json.gz",
             "time": pd.Timestamp("2026-01-01T00:00:00Z") + pd.Timedelta(milliseconds=10 * i)}
            for i in range(n)]


def test_table4_sampling_column_reflects_the_runs_own_calibration_config(tmp_path):
    """N differs by orders of magnitude between iteration-based and duration-calibrated
    VUS levels; the Sampling column must say which regime produced each row rather than
    leaving readers to infer it from the jump in N alone."""
    rows = _scan_rows("28", 2, 1) + _scan_rows("28", 8, 1)
    metadata = {"suite_config": {"calibration": {"affected_levels": [8], "target_duration_s": 60}}}
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path), metadata=metadata)

    table4 = pd.read_csv(tmp_path / "tables" / "table4_concurrency_scan_summary_pooled.csv")
    sampling = dict(zip(table4["Concurrency (VUS)"], table4["Sampling"]))
    assert sampling[2] == "Iteration-based"
    assert sampling[8] == "Duration-calibrated (~60s)"


def test_table4_sampling_column_is_explicit_when_metadata_is_missing(tmp_path):
    """No run_metadata.json (or an old one predating this field) must not make the column
    silently guess -- it should say so rather than mislabel a row."""
    rows = _scan_rows("28", 8, 1)
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path))  # metadata omitted
    table4 = pd.read_csv(tmp_path / "tables" / "table4_concurrency_scan_summary_pooled.csv")
    assert table4["Sampling"].iloc[0] == "unknown (run_metadata.json not available)"


def test_baseline_warns_when_only_one_repetition_is_present(tmp_path, capsys):
    rows = [{"metric": "http_req_duration", "value": 5.0, "status": "200", "phase": "baseline",
             "tier": "28", "rep": "1", "source_file": "baseline_28_rep1.json.gz",
             "time": pd.Timestamp("2026-01-01T00:00:00Z")}]
    results.analyze_baseline(pd.DataFrame(rows), str(tmp_path))
    assert "Only 1 repetition detected" in capsys.readouterr().out


def test_scan_warns_when_only_one_repetition_is_present(tmp_path, capsys):
    rows = _scan_rows("28", 8, 1)
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path))
    assert "Only 1 repetition detected" in capsys.readouterr().out


def test_baseline_and_scan_do_not_warn_with_enough_reps(tmp_path, capsys):
    rows = _scan_rows("28", 8, 1) + _scan_rows("28", 8, 2)
    results.analyze_scan(pd.DataFrame(rows), str(tmp_path))
    assert "repetition detected" not in capsys.readouterr().out


# GC log parsing

GC_LOG = """[2026-01-01T12:00:00.100+0000][0.512s][info][gc,init] Version: 21.0.5+11
[2026-01-01T12:00:01.100+0000][1.000s][info][gc] GC(0) Pause Young (Normal) (G1 Evacuation Pause) 128M->40M(1536M) 2.500ms
[2026-01-01T12:00:05.100+0000][5.000s][info][gc,phases] GC(1) Evacuate Collection Set: 1.2ms
[2026-01-01T12:00:09.100+0000][9.000s][info][gc] GC(2) Pause Young (Normal) (G1 Evacuation Pause) 130M->42M(1536M) 3.750ms
[2026-01-01T12:01:00.100+0000][60.000s][info][gc,heap,exit] Heap
"""


def test_parse_gc_log_extracts_only_bare_gc_pause_lines(tmp_path):
    log = tmp_path / "gc_scan_rep1.log"
    log.write_text(GC_LOG)
    pauses, window_s, _ = results.parse_gc_log(str(log))
    assert [d for _, d in pauses] == [2.5, 3.75]
    assert window_s == pytest.approx(60.0)


def test_parse_gc_log_spans_the_window_by_wall_clock_across_the_two_jvms(tmp_path):
    """The archived log opens with the last pin-check probe JVM's own lines (uptime
    near zero), then continues with the service JVM's (uptime since it started, 3.4s
    earlier). An uptime difference would add those 3.4s to the window."""
    log = tmp_path / "gc_baseline_rep1.log"
    log.write_text(
        "[2026-01-01T12:00:00.000+0000][0.001s][info][gc     ] Using G1\n"
        "[2026-01-01T12:00:00.020+0000][0.020s][info][gc,heap,exit] Heap\n"
        "[2026-01-01T12:00:10.000+0000][13.400s][info][gc] GC(7) Pause Young (Normal) "
        "(G1 Evacuation Pause) 128M->40M(1536M) 2.000ms\n"
        "[2026-01-01T12:03:00.000+0000][183.400s][info][gc,heap,exit] Heap\n")
    pauses, window_s, collector = results.parse_gc_log(str(log))
    assert collector == "G1" and [d for _, d in pauses] == [2.0]
    assert window_s == pytest.approx(180.0)


def test_parse_gc_log_confirmed_g1_zero_pauses_is_informational_not_a_warning(tmp_path, capsys):
    log = tmp_path / "gc_scan_rep2.log"
    log.write_text("[2026-01-01T12:00:00.100+0000][0.001s][info][gc     ] Using G1\n")
    pauses, _, _ = results.parse_gc_log(str(log))
    assert pauses == []
    out = capsys.readouterr().out
    assert "G1 confirmed selected" in out
    assert "WARNING" not in out


def test_parse_gc_log_warns_by_name_when_a_different_collector_is_confirmed(tmp_path, capsys):
    log = tmp_path / "gc_scan_rep2.log"
    log.write_text("[2026-01-01T12:00:00.100+0000][0.001s][info][gc     ] Using Serial\n")
    pauses, _, _ = results.parse_gc_log(str(log))
    assert pauses == []
    out = capsys.readouterr().out
    assert "WARNING" in out
    assert "selected 'Serial', not G1" in out


def test_parse_gc_log_warns_unknown_when_no_startup_line_is_present(tmp_path, capsys):
    log = tmp_path / "gc_scan_rep2.log"
    log.write_text("[2026-01-01T12:00:00.100+0000][0.512s][info][gc,init] Version: 21.0.5+11\n")
    pauses, _, _ = results.parse_gc_log(str(log))
    assert pauses == []
    out = capsys.readouterr().out
    assert "WARNING" in out
    assert "Collector identity unknown" in out


# k6 JSON loading

def _point(metric, value, tags, ts="2026-01-01T00:00:00.000000Z"):
    return json.dumps({"type": "Point", "metric": metric,
                       "data": {"time": ts, "value": value, "tags": tags}})


def test_load_results_extracts_tags_and_skips_non_point_records(tmp_path):
    tags = {"strategy": "DISTRIBUTED_AI_SYNCHRONOUS", "tier": "28", "vus": "64",
            "phase": "scan", "rep": "3", "status": "200"}
    (tmp_path / "scan_28_vus64_rep3.json").write_text(
        json.dumps({"type": "Metric", "metric": "http_req_duration", "data": {}}) + "\n"
        + _point("http_req_duration", 5.5, tags) + "\n"
        + "{ not json\n"
        + _point("python_model_inference_time_ms", 3.0, tags) + "\n"
    )
    df, true_counts = results.load_results(str(tmp_path), prefixes=("scan_",))
    assert len(df) == 2
    assert set(df["metric"]) == {"http_req_duration", "python_model_inference_time_ms"}
    assert df["vus"].tolist() == [64, 64]
    assert df["rep"].tolist() == ["3", "3"]
    assert int(true_counts["true_n"].sum()) == 2


def test_load_results_returns_none_when_no_file_matches_the_prefix(tmp_path):
    (tmp_path / "baseline_28_rep1.json").write_text(_point("http_req_duration", 1.0, {"tier": "28"}) + "\n")
    assert results.load_results(str(tmp_path), prefixes=("scan_",)) == (None, None)


def test_load_results_raises_when_the_directory_holds_nothing(tmp_path):
    with pytest.raises(FileNotFoundError):
        results.load_results(str(tmp_path))


# error accounting

def test_error_summary_splits_timeouts_from_http_errors(tmp_path):
    tags = {"tier": "28", "phase": "scan"}
    lines = ([_point("http_req_duration", 5.0, dict(tags, status="200"))] * 7
             + [_point("http_req_duration", 5.0, dict(tags, status="502"))] * 2
             + [_point("http_req_duration", 0.0, dict(tags, status="0"))])
    (tmp_path / "scan_28_vus1_rep1.json").write_text("\n".join(lines) + "\n")
    df, _ = results.load_results(str(tmp_path), prefixes=("scan_",))
    table = results.error_summary(df, "scan", ["tier"], lambda k: results._tier_label(k[0]))
    row = table.iloc[0]
    assert row["Total Requests"] == 10
    assert row["Successful (200)"] == 7
    assert row["HTTP Errors (non-200 response)"] == 2
    assert row["Timeouts / Network Errors (no response)"] == 1
    assert row["Error Rate (%)"] == pytest.approx(30.0)


def test_error_summary_uses_true_n_for_successful_when_given_true_counts(tmp_path):
    """HTTP Errors/Timeouts are already exact (exempt from the reservoir), so only
    Successful needs a true_counts correction; Total Requests and Error Rate must
    follow from the corrected Successful, not the pre-correction len(g)."""
    tags = {"tier": "28", "phase": "scan"}
    lines = ([_point("http_req_duration", 5.0, dict(tags, status="200"))] * 3
             + [_point("http_req_duration", 5.0, dict(tags, status="502"))] * 2)
    (tmp_path / "scan_28_vus1_rep1.json").write_text("\n".join(lines) + "\n")
    df, _ = results.load_results(str(tmp_path), prefixes=("scan_",))
    true_counts = pd.DataFrame([{
        "metric": "http_req_duration", "tier": "28", "phase": "scan", "status": "200",
        "true_n": 9000, "true_min_time": pd.NaT, "true_max_time": pd.NaT,
    }])
    table = results.error_summary(df, "scan", ["tier"], lambda k: results._tier_label(k[0]),
                                  true_counts=true_counts)
    row = table.iloc[0]
    assert row["Successful (200)"] == 9000
    assert row["HTTP Errors (non-200 response)"] == 2
    assert row["Total Requests"] == 9002
    assert row["Error Rate (%)"] == pytest.approx(round(100 * 2 / 9002, 2))


def test_summarize_reports_true_n_when_given_true_counts():
    """The corrected count is display-only: mean/percentiles must still come from
    the sample actually passed in, not be invented from the true count."""
    sub_df = pd.DataFrame({"value": [1.0, 2.0, 3.0], "rep": ["1", "1", "1"]})
    true_counts = pd.DataFrame([{
        "metric": "http_req_duration", "tier": "28", "phase": "scan", "status": "200",
        "true_n": 500, "true_min_time": pd.NaT, "true_max_time": pd.NaT,
    }])
    stats = results.summarize(sub_df, "v28 @ VUS=8", true_counts=true_counts,
                              metric="http_req_duration", tier="28", phase="scan", status="200")
    assert stats["N (pooled, all reps)"] == 500
    assert stats["Mean (ms)"] == pytest.approx(2.0)


def test_summarize_falls_back_to_sample_n_without_a_true_counts_match():
    """A filter that matches nothing (or true_counts=None) must not zero out N --
    the sample count is what's actually known in that case."""
    sub_df = pd.DataFrame({"value": [1.0, 2.0, 3.0], "rep": ["1", "1", "1"]})
    stats = results.summarize(sub_df, "v28 @ VUS=8")
    assert stats["N (pooled, all reps)"] == 3


# --- GC log parsing, effect size, and throughput edge cases ---

SERIAL_PAUSE_LOG = (
    "[2026-01-01T12:00:00.000+0000][0.005s][info][gc     ] Using Serial\n"
    "[2026-01-01T12:00:00.100+0000][0.105s][info][gc          ] "
    "GC(0) Pause Young (Allocation Failure) 18M->2M(61M) 1.146ms\n"
)


def test_parse_gc_log_warns_when_a_non_g1_collector_produced_parsable_pauses(tmp_path, capsys):
    """Serial/Parallel/Shenandoah emit the same generic "GC(N) Pause ..." record as G1,
    so a log whose pauses parse is not by itself evidence that G1 produced them."""
    log = tmp_path / "gc_scan_rep1.log"
    log.write_text(SERIAL_PAUSE_LOG)
    pauses, _, collector = results.parse_gc_log(str(log))
    assert len(pauses) == 1                 # the pause really does parse
    assert collector == "Serial"
    out = capsys.readouterr().out
    assert "WARNING" in out and "Serial" in out and "not G1" in out


def test_parse_gc_log_reports_the_collector_it_found(tmp_path):
    """GC_LOG deliberately has no startup line, so this needs its own fixture."""
    log = tmp_path / "gc_scan_rep1.log"
    log.write_text("[2026-01-01T12:00:00.000+0000][0.005s][info][gc     ] Using G1\n"
                   "[2026-01-01T12:00:01.000+0000][1.000s][info][gc          ] "
                   "GC(0) Pause Young (Normal) (G1 Evacuation Pause) 128M->40M(1536M) 2.500ms\n")
    pauses, _, collector = results.parse_gc_log(str(log))
    assert collector == "G1" and len(pauses) == 1


def test_effect_size_matches_brute_force_cliffs_delta():
    """Guards the sign convention, which a magnitude-only test cannot."""
    from scipy.stats import mannwhitneyu
    a, b = np.arange(1.0, 8.0), np.arange(10.0, 17.0)
    u, _ = mannwhitneyu(a, b, alternative="two-sided")
    brute = np.mean([np.sign(x - y) for x in a for y in b])
    assert results.rank_biserial_effect_size(u, len(a), len(b)) == pytest.approx(brute)
    assert brute < 0                        # A below B must be negative, as Cliff's delta


def test_untagged_rep_warning_ignores_k6_engine_metrics(tmp_path, capsys):
    """k6 engine metrics carry no request tags by design and enter no reported statistic."""
    rows = [json.dumps({"type": "Point", "metric": m, "data": {
        "time": "2026-01-01T00:00:00.000000Z", "value": 1.0, "tags": {"scenario": "s"}}})
            for m in ("data_sent", "iterations", "vus")]
    (tmp_path / "scan_28_vus1_rep1.json").write_text("\n".join(rows) + "\n")
    results.load_results(str(tmp_path), prefixes=("scan_",))
    assert "carry no 'rep' tag" not in capsys.readouterr().out


def test_dropped_iterations_outside_openloop_are_reported(tmp_path, capsys):
    """A cell that hits maxDuration exits 0 and books the unrun iterations as drops."""
    pt = json.dumps({"type": "Point", "metric": "dropped_iterations", "data": {
        "time": "2026-01-01T00:00:00.000000Z", "value": 7.0, "tags": {"scenario": "s"}}})
    (tmp_path / "warmup_baseline_rep1.json").write_text(pt + "\n")
    results.load_results(str(tmp_path), prefixes=("warmup_",))
    out = capsys.readouterr().out
    assert "dropped in non-open-loop cell" in out and "warmup_baseline_rep1" in out


def _openloop_rows(source_file, phase, rate, tier, n_ok, n_dropped, rep="1"):
    """N http_req_duration=200 points (tagged, as sendTransaction() sets them) plus
    N untagged dropped_iterations points (as k6 actually emits them -- no phase/rate/tier,
    since an unexecuted iteration never reaches http.post())."""
    rows = []
    for _ in range(n_ok):
        rows.append({"metric": "http_req_duration", "value": 10.0, "status": "200",
                     "phase": phase, "tier": tier, "rate": rate, "rep": rep,
                     "vus": np.nan, "source_file": source_file,
                     "time": pd.Timestamp("2026-01-01T00:00:00Z")})
    for _ in range(n_dropped):
        rows.append({"metric": "dropped_iterations", "value": 1.0, "status": np.nan,
                     "phase": np.nan, "tier": np.nan, "rate": np.nan, "rep": np.nan,
                     "vus": np.nan, "source_file": source_file,
                     "time": pd.Timestamp("2026-01-01T00:00:00Z")})
    return rows


def test_openloop_check_excludes_smoke_test_artifact(tmp_path, capsys):
    """run-smoke-test.sh's deliberately-unsustainable RATE=5000 cell (phase=smoke-openloop)
    must never be reported as a real table7 validity check."""
    rows = _openloop_rows("openloop_28_smoke.json", "smoke-openloop", "5000", "28",
                           n_ok=10, n_dropped=80)
    df = pd.DataFrame(rows)
    results.analyze_openloop_check(df, str(tmp_path))
    out = capsys.readouterr().out
    assert "excluded 10 smoke-test open-loop point" in out
    assert not (tmp_path / "tables" / "table7_openloop_validity_check.csv").exists()


def test_openloop_check_reports_real_check_without_smoke_contamination(tmp_path, capsys):
    """A real check (phase=openloop-check) alongside a leftover smoke file for the same
    tier must be reported on its own -- not pooled with, and not replaced by, the smoke
    cell's drop count."""
    rows = (_openloop_rows("openloop_28_smoke.json", "smoke-openloop", "5000", "28",
                            n_ok=10, n_dropped=80)
            + _openloop_rows("openloop_28_rate32.json", "openloop-check", "32", "28",
                              n_ok=20, n_dropped=1))
    df = pd.DataFrame(rows)
    results.analyze_openloop_check(df, str(tmp_path))
    out = capsys.readouterr().out
    assert "excluded 10 smoke-test open-loop point" in out

    table = pd.read_csv(tmp_path / "tables" / "table7_openloop_validity_check.csv")
    ol_rows = table[table["Model"].str.startswith("Open-loop")]
    assert len(ol_rows) == 1
    assert ol_rows.iloc[0]["Model"] == "Open-loop (rate=32/s)"
    assert ol_rows.iloc[0]["Dropped iterations"] == 1
    assert ol_rows.iloc[0]["N"] == 20


def test_openloop_check_compares_against_the_scan_levels_this_run_actually_used(tmp_path):
    """The closed-loop rows -- and Table 7's caption -- must name whichever concurrency
    levels this run's scan phase actually used, not a hardcoded VUS 32/64: a
    CONCURRENCY_OVERRIDE run would otherwise get a caption naming levels it never ran."""
    rows = _openloop_rows("openloop_28_rate32.json", "openloop-check", "32", "28", n_ok=20, n_dropped=0)
    for vus in (6, 12):
        for i in range(30):
            rows.append({"metric": "http_req_duration", "value": 5.0, "status": "200",
                         "phase": "scan", "tier": "28", "rate": np.nan, "rep": "1",
                         "vus": float(vus), "source_file": f"scan_28_vus{vus}_rep1.json.gz",
                         "time": pd.Timestamp("2026-01-01T00:00:00Z") + pd.Timedelta(milliseconds=10 * i)})
    results.analyze_openloop_check(pd.DataFrame(rows), str(tmp_path))

    table = pd.read_csv(tmp_path / "tables" / "table7_openloop_validity_check.csv")
    cl_rows = table[table["Model"].str.startswith("Closed-loop")]
    assert sorted(cl_rows["Model"].tolist()) == ["Closed-loop VUS=12", "Closed-loop VUS=6"]

    tex = (tmp_path / "tables" / "table7_openloop_validity_check.tex").read_text()
    assert "VUS 6/12" in tex
    assert "32/64" not in tex


def test_between_run_sd_is_not_estimable_from_one_rep():
    """0.0 would read as perfect consistency rather than "not estimable"."""
    one = pd.DataFrame([{"metric": "m", "phase": "baseline", "tier": "v5",
                         "rep": "1", "value": 10.0}])
    out = results.between_run_consistency(one, "m", "baseline", ["tier"], lambda k: k[0])
    assert np.isnan(out["StdDev Across Reps (ms)"].iloc[0])


# --- warm-up convergence (table0) ---

# Both bounds are in the header, so a reader can tell which one admitted a target.
CONVERGED_COL = "Converged (tail <5% or <0.25ms)"
WINDOW = 500


def _shell_const(script, name):
    """Reads a top-level constant out of a load-testing script's text."""
    text = (LOAD_TESTING_DIR / script).read_text()
    return re.search(rf"^{name}=(\S+)$", text, re.M).group(1)


def _warmup_file(path, segments, step_ms=10, gz=True):
    """A k6 warm-up result file whose HTTP 200 latencies run through `segments`
    ((tier, value, count[, status]) tuples) in time order, one point every step_ms,
    written the way converge_warmup() leaves it."""
    lines, i = [], 0
    base = pd.Timestamp("2026-01-01T00:00:00Z")
    for seg in segments:
        tier, value, count = seg[:3]
        status = seg[3] if len(seg) > 3 else "200"
        for _ in range(count):
            t = (base + pd.Timedelta(milliseconds=i * step_ms)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            lines.append(json.dumps({"metric": "http_req_duration", "type": "Point", "data": {
                "time": t, "value": value, "tags": {"tier": tier, "status": status, "phase": "warmup"}}}))
            i += 1
    text = "\n".join(lines) + "\n"
    if gz:
        with gzip.open(path, "wt") as f:
            f.write(text)
    else:
        path.write_text(text)


def _metadata(tmp_path, targets, **gate):
    (tmp_path / "run_metadata.json").write_text(json.dumps(
        {"suite_config": {"targets": targets, **({"warmup_gate": gate} if gate else {})}}))
    return results.read_run_metadata(str(tmp_path))


def _table0(tmp_path, targets=("28",)):
    return results.analyze_warmup(str(tmp_path), str(tmp_path / "out"), _metadata(tmp_path, list(targets)))


def test_warmup_criterion_defaults_match_the_live_shell_gate():
    """A run without recorded parameters is judged at the module's defaults, which
    must be the constants both scripts run the gate at."""
    params = warmup_check.gate_params()
    for script in ("run-suite.sh", "run-ablation.sh"):
        assert int(_shell_const(script, "WARMUP_WINDOW")) == params["base_window"] == WINDOW
        assert float(_shell_const(script, "WARMUP_WINDOW_MIN_S")) == params["min_span_s"]
        assert float(_shell_const(script, "WARMUP_TAIL_TOLERANCE_PCT")) == params["tol_pct"] == 5.0
        assert float(_shell_const(script, "WARMUP_TAIL_ABS_FLOOR_MS")) == params["floor_ms"] == 0.25


def test_both_analysis_scripts_judge_warmup_with_the_live_gate_module():
    assert warmup_check.gate.evaluate is results.warmup_gate.evaluate
    assert Path(warmup_check.GATE_PATH).resolve() == (LOAD_TESTING_DIR / "lib" / "warmup_gate.py").resolve()


def test_table0_reports_the_gates_verdict_per_target(tmp_path):
    _warmup_file(tmp_path / "warmup_scan_rep1.json.gz",
                 [("mock", 0.20, 2 * WINDOW), ("mock", 0.40, WINDOW),
                  ("28", 100.0, 2 * WINDOW), ("28", 102.0, WINDOW),
                  ("5", 10.0, 2 * WINDOW), ("5", 20.0, WINDOW)])
    table = _table0(tmp_path, ["mock", "5", "28"]).set_index("Tier")
    # The absolute floor admits mock's 0.2 ms gap despite 100% drift; the percentage
    # bound admits v28's 2%; v5 fails both.
    assert table.loc["mock", CONVERGED_COL] == "YES"
    assert table.loc["v28", CONVERGED_COL] == "YES"
    assert table.loc["v5", CONVERGED_COL] == "no"
    assert table.loc["v5", "Status"] == "drifting"
    assert table.loc["v5", "Tail drift (%)"] == pytest.approx(100.0)


def test_table0_keeps_every_expected_target_including_the_ones_that_failed(tmp_path, capsys):
    """A target that never reached three windows or never returned 200 is the finding;
    dropping its row would make a partially warmed stack read as fully converged."""
    _warmup_file(tmp_path / "warmup_baseline_rep1.json.gz",
                 [("28", 10.0, 3 * WINDOW), ("5", 10.0, 3 * WINDOW - 1), ("10", 900.0, 50, "503")])
    table = _table0(tmp_path, ["28", "5", "10", "20"]).set_index("Tier")
    assert table.loc["v28", "Status"] == "converged"
    assert table.loc["v5", "Status"] == "fewer than three windows"
    assert table.loc["v10", "Status"] == "no HTTP 200 responses"
    assert table.loc["v10", "Failed Requests"] == 50
    assert table.loc["v20", "Status"] == "no requests"
    assert (table.loc[["v5", "v10", "v20"], CONVERGED_COL] == "no").all()
    assert "3/4 warm-up target(s) had not converged" in capsys.readouterr().out


def test_table0_window_spans_the_recorded_minimum_at_a_high_request_rate(tmp_path):
    """At 1 ms per request a 500-request window covers half a second, so a blip in
    the last half second would read as drift; the window is widened to the recorded
    minimum span instead."""
    _warmup_file(tmp_path / "warmup_scan_rep1.json.gz",
                 [("mock", 10.0, 11500), ("mock", 20.0, 500)], step_ms=1)
    table = _table0(tmp_path, ["mock"])
    assert table["Window (requests)"].tolist() == [3500]
    assert table[CONVERGED_COL].tolist() == ["YES"]

    (tmp_path / "out").mkdir(exist_ok=True)
    table = results.analyze_warmup(str(tmp_path), str(tmp_path / "out"),
                                   _metadata(tmp_path, ["mock"], base_window=500, min_window_span_s=0,
                                             tail_tolerance_pct=5.0, tail_abs_floor_ms=0.25))
    assert table["Window (requests)"].tolist() == [500]
    assert table[CONVERGED_COL].tolist() == ["no"]


def test_table0_orders_passes_chronologically_and_reads_plain_and_gzip(tmp_path):
    for name in ("warmup_scan_maxvus_rep1.json.gz", "warmup_scan_rep1.json.gz",
                 "warmup_baseline_rep2.json.gz", "warmup_baseline_rep10.json.gz"):
        _warmup_file(tmp_path / name, [("28", 5.0, 3 * WINDOW)])
    _warmup_file(tmp_path / "warmup_baseline_rep1.json", [("28", 5.0, 3 * WINDOW)], gz=False)
    table = _table0(tmp_path)
    assert table["Source File"].tolist() == [
        "warmup_baseline_rep1.json", "warmup_baseline_rep2.json.gz", "warmup_baseline_rep10.json.gz",
        "warmup_scan_rep1.json.gz", "warmup_scan_maxvus_rep1.json.gz"]


def test_table0_says_when_a_file_was_truncated(tmp_path, capsys):
    whole = tmp_path / "whole.json.gz"
    _warmup_file(whole, [("28", 5.0, 20000)])
    (tmp_path / "warmup_baseline_rep1.json.gz").write_bytes(whole.read_bytes()[: whole.stat().st_size // 2])
    whole.unlink()
    table = _table0(tmp_path)
    assert table["Status"].iloc[0].endswith("(file truncated)")
    assert "compressed stream ended early" in capsys.readouterr().out


def test_table0_caption_names_the_criterion_it_applied(tmp_path):
    _warmup_file(tmp_path / "warmup_baseline_rep1.json.gz", [("28", 5.0, 3 * WINDOW)])
    _table0(tmp_path)
    caption = (tmp_path / "out" / "tables" / "table0_warmup_convergence_check.tex").read_text()
    assert "at least 500 HTTP 200 requests spanning at least 3 s" in caption
    assert "under 5\\% or an absolute gap under 0.25 ms" in caption


def test_table0_without_warmup_files_is_skipped_not_raised(tmp_path, capsys):
    assert results.analyze_warmup(str(tmp_path), str(tmp_path), {}) is None
    assert "No warmup_* files found" in capsys.readouterr().out


def _ablation_metadata(tmp_path, **extra):
    config = {"target": "28", **extra}
    (tmp_path / "ablation_run_metadata.json").write_text(json.dumps({"ablation_config": config}))
    return ablation.read_metadata(str(tmp_path))


def test_ablation_table0_applies_the_same_gate_per_cell(tmp_path):
    _warmup_file(tmp_path / "ablation_warmup_cpuset_0-1_rep1.json.gz",
                 [("28", 0.20, 2 * WINDOW), ("28", 0.40, WINDOW)])
    _warmup_file(tmp_path / "ablation_warmup_cpuset_2-3_rep1.json.gz",
                 [("28", 10.0, 2 * WINDOW), ("28", 20.0, WINDOW)])
    _warmup_file(tmp_path / "ablation_warmup_thread_limiter_128_rep1.json.gz", [("28", 10.0, 100)])
    table, params = ablation.build_ablation_warmup_table(str(tmp_path), _ablation_metadata(tmp_path))
    table = table.set_index("Value")
    assert warmup_check.converged_column(params) == CONVERGED_COL
    assert table.loc["0-1", CONVERGED_COL] == "YES"
    assert table.loc["2-3", CONVERGED_COL] == "no"
    assert table.loc["128", "Status"] == "fewer than three windows"


def test_ablation_table0_reports_the_target_even_when_it_sent_nothing(tmp_path):
    _warmup_file(tmp_path / "ablation_warmup_workers_1_rep1.json.gz", [("5", 10.0, 3 * WINDOW)])
    table, _ = ablation.build_ablation_warmup_table(str(tmp_path), _ablation_metadata(tmp_path))
    assert table.set_index("Tier").loc["28", "Status"] == "no requests"


# --- reservoir sampling in load_results ---

# analyze-results.py's own cap. Cells are sized by wall-clock duration, so a zero-work
# target logs far more points than a model-inference tier; the cap is what keeps peak
# memory independent of that.
MAX_POINTS_PER_FILE = 250_000

# Named here rather than read back from the module, so dropping one from the exemption
# cannot make the test that guards it vacuously true. Truncated-cell detection sums
# dropped_iterations; the error cross-check sums the other two.
EXEMPT_METRICS = ("dropped_iterations", "request_http_error", "request_timeout_error")


def _sampled_file(path, n_points, exempt=False, n_errors=0):
    """n_points status=200 http_req_duration points with distinct values, so which ones
    survived sampling is observable, plus optionally one point of each exempt metric and
    n_errors non-200 http_req_duration points (distinct negative values, so they can't be
    mistaken for a survived 200 point)."""
    with open(path, "w") as f:
        for i in range(n_points):
            f.write('{"type":"Point","metric":"http_req_duration","data":{"time":'
                    f'"2026-01-01T00:00:00.000000Z","value":{i},'
                    '"tags":{"tier":"28","status":"200","rep":"1","phase":"scan"}}}\n')
        for metric in (EXEMPT_METRICS if exempt else ()):
            f.write(f'{{"type":"Point","metric":"{metric}","data":{{"time":'
                    '"2026-01-01T00:00:00.000000Z","value":1.0,'
                    '"tags":{"scenario":"s"}}}\n')
        for i in range(n_errors):
            f.write('{"type":"Point","metric":"http_req_duration","data":{"time":'
                    f'"2026-01-01T00:00:00.000000Z","value":{-1 - i},'
                    '"tags":{"tier":"28","status":"502","rep":"1","phase":"scan"}}}\n')


@pytest.fixture(scope="module")
def oversized_results_dir(tmp_path_factory):
    """One file past the cap by enough points to exercise many replacement draws,
    shared across the sampling tests -- writing a quarter-million points per test
    would dominate the suite's runtime."""
    d = tmp_path_factory.mktemp("oversized")
    _sampled_file(d / "scan_28_vus64_rep1.json", MAX_POINTS_PER_FILE + 1000, exempt=True)
    return d


@pytest.fixture(scope="module")
def oversized_results_dir_exemptions(tmp_path_factory):
    """A second oversized directory, separate from oversized_results_dir so its extra
    points cannot shift that fixture's already-asserted counts: an oversized scan_
    file with 50 non-200 points mixed into the sampled ones."""
    d = tmp_path_factory.mktemp("oversized_exemptions")
    _sampled_file(d / "scan_28_vus64_rep1.json", MAX_POINTS_PER_FILE + 1000, n_errors=50)
    return d


def test_load_results_keeps_every_point_below_the_sampling_cap(tmp_path, capsys):
    _sampled_file(tmp_path / "scan_28_vus64_rep1.json", 1000)
    df, _ = results.load_results(str(tmp_path), prefixes=("scan_",))
    assert len(df) == 1000
    assert sorted(df["value"].tolist()) == [float(i) for i in range(1000)]
    assert "subsampled" not in capsys.readouterr().out


def test_load_results_bounds_an_oversized_file_to_the_cap(oversized_results_dir, capsys):
    df, _ = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    assert int((df["metric"] == "http_req_duration").sum()) == MAX_POINTS_PER_FILE
    assert f"subsampled to {MAX_POINTS_PER_FILE}" in capsys.readouterr().out


def test_load_results_never_samples_out_the_always_keep_metrics(oversized_results_dir):
    """These counters are rare next to http_req_duration, so a uniform sample thins
    them and a truncated cell reads as clean instead of tripping the check meant to
    catch it. They must arrive on top of a full reservoir, not compete for its slots."""
    assert sorted(results.ALWAYS_KEEP_METRICS) == sorted(EXEMPT_METRICS)
    df, _ = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    assert sorted(df[df["metric"].isin(EXEMPT_METRICS)]["metric"]) == sorted(EXEMPT_METRICS)
    assert len(df) == MAX_POINTS_PER_FILE + len(EXEMPT_METRICS)


def test_load_results_samples_deterministically_from_the_fixed_seed(oversized_results_dir):
    """Re-running the analysis on an unchanged dataset must not move the reported
    numbers; the seed is what makes a sampled table reproducible for the paper."""
    first, _ = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    second, _ = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    assert first["value"].tolist() == second["value"].tolist()


def test_load_results_keeps_every_non_200_point_regardless_of_the_cap(oversized_results_dir_exemptions):
    """Non-200 http_req_duration points feed error_summary()'s status-derived counts,
    which crosscheck_error_counters() compares against the independently-incremented
    request_http_error/request_timeout_error counters. Subsampling them alongside the
    far more numerous 200s would turn that comparison into an estimate instead of an
    exact, genuinely independent cross-check."""
    df, _ = results.load_results(str(oversized_results_dir_exemptions), prefixes=("scan_",))
    non200 = df[(df["metric"] == "http_req_duration") & (df["status"] != "200")]
    assert len(non200) == 50
    assert sorted(non200["value"].tolist()) == sorted([-1.0 - i for i in range(50)])


def test_load_results_reports_true_extremes_despite_subsampling(oversized_results_dir):
    """A uniform sample almost never keeps a file's single smallest and largest point,
    so Min/Max over the sample would understate the range the cell really had."""
    df, true_counts = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    filters = dict(metric="http_req_duration", tier="28", phase="scan", status="200")
    assert results._true_value_range(true_counts, **filters) == (0.0, float(MAX_POINTS_PER_FILE + 999))
    cell = df[(df["metric"] == "http_req_duration") & (df["status"] == "200")]
    stats = results.summarize(cell, "v28", true_counts=true_counts, **filters)
    assert (stats["Min (ms)"], stats["Max (ms)"]) == (0.0, float(MAX_POINTS_PER_FILE + 999))


def test_load_results_true_counts_track_the_full_count_despite_subsampling(oversized_results_dir):
    """true_n for a subsampled metric is the number of points that actually existed
    (MAX_POINTS_PER_FILE + 1000, from the oversized_results_dir fixture), not the
    number the reservoir kept -- the whole point of the true-count side channel."""
    df, true_counts = results.load_results(str(oversized_results_dir), prefixes=("scan_",))
    match = true_counts[
        (true_counts["metric"] == "http_req_duration") & (true_counts["status"] == "200")
        & (true_counts["tier"] == "28") & (true_counts["phase"] == "scan") & (true_counts["rep"] == "1")
    ]
    assert int(match["true_n"].sum()) == MAX_POINTS_PER_FILE + 1000
    assert int((df["metric"] == "http_req_duration").sum()) == MAX_POINTS_PER_FILE


def test_true_counts_keeps_different_rate_cells_of_the_same_tier_separate(tmp_path):
    """Open-loop cells share tier/phase/rep across different RATEs (unlike scan/baseline,
    which never tag rate at all), so true_counts must key on rate too -- otherwise two
    open-loop cells at the same tier would sum into one inflated true_n."""
    tags = {"tier": "28", "phase": "openloop-check", "rep": "1", "status": "200"}
    lines_16 = [_point("http_req_duration", 1.0, dict(tags, rate="16"))] * 30
    lines_32 = [_point("http_req_duration", 1.0, dict(tags, rate="32"))] * 70
    (tmp_path / "openloop_28_rate16.json").write_text("\n".join(lines_16) + "\n")
    (tmp_path / "openloop_28_rate32.json").write_text("\n".join(lines_32) + "\n")
    _, true_counts = results.load_results(str(tmp_path), prefixes=("openloop_",))
    n16 = int(true_counts.loc[true_counts["rate"] == "16", "true_n"].sum())
    n32 = int(true_counts.loc[true_counts["rate"] == "32", "true_n"].sum())
    assert (n16, n32) == (30, 70)


def _sampled_file_over_time(path, n_points, duration_s, extra_metrics=()):
    """n_points status=200 http_req_duration points spread evenly over duration_s
    (so true throughput is exactly (n_points - 1) / duration_s), plus, at each of
    those same timestamps, one point for each of extra_metrics: several metrics
    sharing one point budget per file, none of them individually near the cap."""
    step = duration_s / (n_points - 1) if n_points > 1 else 0.0
    with open(path, "w") as f:
        for i in range(n_points):
            us = round(i * step * 1e6)
            ts = "2026-01-01T00:%02d:%02d.%06dZ" % (us // 60000000, us // 1000000 % 60, us % 1000000)
            f.write('{"type":"Point","metric":"http_req_duration","data":{"time":'
                    f'"{ts}","value":{i},'
                    '"tags":{"tier":"28","status":"200","rep":"1","phase":"scan","vus":"8"}}}\n')
            for metric in extra_metrics:
                f.write(f'{{"type":"Point","metric":"{metric}","data":{{"time":'
                        f'"{ts}","value":1.0,'
                        '"tags":{"tier":"28","status":"200","rep":"1","phase":"scan","vus":"8"}}}\n')


def test_throughput_is_not_deflated_by_cross_metric_reservoir_sharing(tmp_path):
    """One metric's own point count stays under MAX_POINTS_PER_FILE, but several
    metrics sharing that file's single reservoir push the combined total over it, so
    http_req_duration itself is subsampled and (n-1)/span over the sample would read
    at roughly the subsampling ratio instead of the metric's true rate."""
    n_points = MAX_POINTS_PER_FILE // 3
    duration_s = 60.0
    true_throughput = (n_points - 1) / duration_s
    extra_metrics = [f"python_metric_{i}_ms" for i in range(9)]  # 10 metrics/point total
    _sampled_file_over_time(tmp_path / "scan_28_vus8_rep1.json", n_points, duration_s, extra_metrics)
    df, true_counts = results.load_results(str(tmp_path), prefixes=("scan_",))

    n_kept = int(((df["metric"] == "http_req_duration") & (df["status"] == "200")).sum())
    assert n_kept < n_points  # the bug's precondition: this file really did get subsampled

    cell = df[(df["metric"] == "http_req_duration") & (df["status"] == "200")]
    uncorrected = results._throughput_reqs_per_s(cell)
    assert uncorrected < true_throughput * 0.9  # deflated by roughly the subsampling ratio

    corrected = results._throughput_reqs_per_s(
        cell, true_counts=true_counts, metric="http_req_duration",
        phase="scan", status="200", tier="28", vus=8,
    )
    assert corrected == pytest.approx(true_throughput, rel=1e-6)


# --- significance floor at low rep counts ---

def _rep_means_df(tier, values, phase="baseline"):
    return [{"metric": "http_req_duration", "phase": phase, "tier": tier,
              "rep": str(i + 1), "value": v} for i, v in enumerate(values)]


def test_pairwise_mannwhitney_warns_when_even_perfect_separation_cannot_reach_alpha(capsys):
    """At 2 reps/side the minimum achievable two-sided p-value is 0.333, so this
    comparison reads "Significant: No" even though the two groups are perfectly
    separated -- indistinguishable, without the warning, from an actual null result."""
    df = pd.DataFrame(_rep_means_df("5", [1.0, 1.1]) + _rep_means_df("28", [100.0, 101.0]))
    table = results.pairwise_mannwhitney(df, "http_req_duration", "baseline", "tier",
                                          ["5", "28"], lambda t: f"v{t}")
    assert table.iloc[0]["Significant (Holm, alpha=0.05)"] == "No"
    out = capsys.readouterr().out
    assert "even perfect" in out and "v5 vs v28" in out


def test_pairwise_mannwhitney_no_warning_once_alpha_is_reachable(capsys):
    """At 4 reps/side the minimum achievable p (~0.029) clears alpha=0.05, so the
    warning must not fire and muddy a comparison that is actually well-powered."""
    df = pd.DataFrame(_rep_means_df("5", [1.0, 1.1, 1.2, 1.3])
                       + _rep_means_df("28", [100.0, 101.0, 102.0, 103.0]))
    results.pairwise_mannwhitney(df, "http_req_duration", "baseline", "tier",
                                  ["5", "28"], lambda t: f"v{t}")
    assert "even perfect" not in capsys.readouterr().out


# --- table7: a totally overloaded open-loop cell must not vanish ---

def _overloaded_openloop_rows(source_file, phase, rate, tier, n_failed, n_dropped, rep="1"):
    """Every attempted request timed out (status=0, k6's no-response code) -- the
    totally-overloaded case: zero 200 responses, but the cell must still be
    identifiable via its non-200 http_req_duration points."""
    rows = []
    for _ in range(n_failed):
        rows.append({"metric": "http_req_duration", "value": 5000.0, "status": "0",
                     "phase": phase, "tier": tier, "rate": rate, "rep": rep,
                     "vus": np.nan, "source_file": source_file,
                     "time": pd.Timestamp("2026-01-01T00:00:00Z")})
    for _ in range(n_dropped):
        rows.append({"metric": "dropped_iterations", "value": 1.0, "status": np.nan,
                     "phase": np.nan, "tier": np.nan, "rate": np.nan, "rep": np.nan,
                     "vus": np.nan, "source_file": source_file,
                     "time": pd.Timestamp("2026-01-01T00:00:00Z")})
    return rows


def test_openloop_check_reports_a_totally_overloaded_cell_instead_of_dropping_it(tmp_path):
    """A cell where every request timed out (zero 200 responses) must still get a row
    carrying its dropped_iterations count -- the exact overload signal table7 exists
    to surface -- instead of vanishing because cell identity was built from 200-only
    data."""
    rows = _overloaded_openloop_rows("openloop_28_rate5000.json", "openloop-check", "5000", "28",
                                      n_failed=50, n_dropped=200)
    df = pd.DataFrame(rows)
    results.analyze_openloop_check(df, str(tmp_path))
    table = pd.read_csv(tmp_path / "tables" / "table7_openloop_validity_check.csv")
    ol_rows = table[table["Model"].str.startswith("Open-loop")]
    assert len(ol_rows) == 1
    assert ol_rows.iloc[0]["Dropped iterations"] == 200
    assert pd.isna(ol_rows.iloc[0]["P95 (ms)"])
    assert ol_rows.iloc[0]["N"] == 0


# --- silent success on empty/missing input ---

def test_crosscheck_error_counters_warns_when_no_duration_table_to_check_against(capsys):
    """No http_req_duration-derived table (e.g. that phase's load pass was skipped)
    must be reported, not read as a passing cross-check."""
    df = pd.DataFrame({"phase": [], "metric": [], "value": []})
    results.crosscheck_error_counters(df, "scan", ["tier"], lambda k: str(k[0]), None)
    assert "did not run for this phase" in capsys.readouterr().out


def test_analyze_measurement_floor_warns_when_the_floor_tier_has_no_rows(tmp_path, capsys):
    """floor_tier listed in the run's order but producing zero rows (e.g. a failed
    calibration cell) must explain why table1e is absent."""
    e2e = pd.DataFrame({"tier": ["5", "5"], "value": [10.0, 12.0]})
    results.analyze_measurement_floor(e2e, ["calibration", "5"], str(tmp_path))
    assert "no valid values" in capsys.readouterr().out


def test_analyze_gc_logs_warns_when_a_rep_has_no_parsable_records(tmp_path, capsys):
    """A gc log with zero parsable lines produces a NaN gc_overhead_pct, which fails the
    ">1.0" comparison silently and would read as a rep genuinely under 1%."""
    gc_dir = tmp_path / "gc-logs"
    gc_dir.mkdir()
    (gc_dir / "gc_baseline_rep1.log").write_text("")
    results.analyze_gc_logs(str(tmp_path), str(tmp_path))
    out = capsys.readouterr().out
    assert "no measurable GC overhead" in out
    assert "<=1% of wall-clock time in all reps" not in out


# --- load_results edge cases ---

def test_load_results_keeps_what_a_truncated_gzip_decompressed(tmp_path, capsys):
    tags = {"tier": "28", "phase": "scan", "rep": "1", "status": "200", "vus": "8"}
    whole = tmp_path / "whole.gz"
    with gzip.open(whole, "wt") as f:
        for i in range(20000):
            f.write(_point("http_req_duration", float(i), tags) + "\n")
    (tmp_path / "scan_28_vus8_rep1.json.gz").write_bytes(whole.read_bytes()[: whole.stat().st_size // 2])
    whole.unlink()
    df, _ = results.load_results(str(tmp_path), prefixes=("scan_",))
    assert 0 < len(df) < 20000
    assert "compressed stream ended early" in capsys.readouterr().out


def test_true_time_span_orders_go_trimmed_timestamps_numerically(tmp_path):
    """Go trims trailing zeros, so '...:07Z' sorts after '...:07.5Z' as a string."""
    tags = {"tier": "28", "phase": "scan", "rep": "1", "status": "200", "vus": "8"}
    stamps = ["2026-01-01T00:00:07.5Z", "2026-01-01T00:00:07Z", "2026-01-01T00:00:08.25Z"]
    (tmp_path / "scan_28_vus8_rep1.json").write_text(
        "\n".join(_point("http_req_duration", 1.0, tags, ts=t) for t in stamps) + "\n")
    _, true_counts = results.load_results(str(tmp_path), prefixes=("scan_",))
    n, t_min, t_max = results._true_n_and_span(true_counts, metric="http_req_duration")
    assert n == 3
    assert (t_max - t_min).total_seconds() == pytest.approx(1.25)


# --- cpu-pin log re-verification ---

def test_cpu_pin_log_treats_an_unreadable_cgroup_as_skipped_not_mismatched(tmp_path, capsys):
    (tmp_path / "cpu_pin_check_log.txt").write_text(
        "cpu_pin_check label=scan rep=1 python_requested=0-1 python_live=EMPTY java_requested=2-3 java_live=EMPTY\n"
        "cpu_pin_check label=scan rep=1 python_live=UNREADABLE java_live=UNREADABLE result=WARN_SKIPPED\n"
        "cpu_pin_check label=scan rep=1 k6_live=10-11 k6_expected=10-11\n")
    results.check_cpu_pin_log(str(tmp_path))
    out = capsys.readouterr().out
    assert "1 live cgroup cpuset check(s) were skipped" in out
    assert "1 checks verified, all matched" in out
    assert "WARNING" not in out


def test_cpu_pin_log_still_flags_a_real_mismatch(tmp_path, capsys):
    (tmp_path / "cpu_pin_check_log.txt").write_text(
        "cpu_pin_check label=scan rep=1 jvm_effective_cpu_count=EMPTY expected_from_cpuset=4\n"
        "cpu_pin_check label=scan rep=1 k6_live=10-12 k6_expected=10-11\n")
    results.check_cpu_pin_log(str(tmp_path))
    assert "2/2 checks mismatched" in capsys.readouterr().out


# --- table1e ---

def test_measurement_floor_covers_model_tiers_and_exempts_mock(tmp_path):
    """mock adds only a random draw to calibration's path, so its fastest requests fall
    below calibration's single fastest one by sampling alone."""
    e2e = pd.DataFrame({"tier": ["calibration"] * 3 + ["mock"] * 3 + ["28"] * 3,
                        "value": [1.0, 1.2, 1.4, 0.9, 1.1, 1.3, 0.8, 6.0, 7.0]})
    results.analyze_measurement_floor(e2e, ["calibration", "mock", "28"], str(tmp_path))
    table = pd.read_csv(tmp_path / "tables" / "table1e_measurement_floor_violations.csv")
    assert table["Group"].tolist() == ["v28"]
    assert table["Below floor (n)"].tolist() == [1]


def test_latex_captions_escape_what_latex_would_misread(tmp_path):
    results.save_table(pd.DataFrame({"a": [1]}), "t", str(tmp_path),
                       caption="under 5% of therm_throt a&b #1, already 95\\% escaped")
    tex = (tmp_path / "tables" / "t.tex").read_text()
    assert "under 5\\% of therm\\_throt a\\&b \\#1, already 95\\% escaped" in tex


# --- thermal telemetry ---

def _shell_trace(tmp_path):
    """A trace written by lib/thermal.sh itself against a synthetic sysfs tree, so the
    parser is held to the format the harness actually emits."""
    sysfs = tmp_path / "sys"
    (sysfs / "class/thermal/thermal_zone0").mkdir(parents=True)
    for cpu in range(4):
        (sysfs / f"devices/system/cpu/cpu{cpu}/thermal_throttle").mkdir(parents=True)
    trace = tmp_path / "env_trace_log.txt"
    script = f"""
set -euo pipefail
THERMAL_SYSFS_ROOT={sysfs}; ENV_TRACE_LOG={trace}
THERMAL_WARN_C=90; THERMAL_CRIT_C=95; THERMAL_COOLDOWN_S=60; MAX_THERMAL_COOLDOWNS=2
abort_suite() {{ exit 1; }}
sleep() {{ echo 80000 > {sysfs}/class/thermal/thermal_zone0/temp; }}
. {LOAD_TESTING_DIR}/lib/thermal.sh
set_state() {{
  echo "$1" > {sysfs}/class/thermal/thermal_zone0/temp
  for c in 0 1 2 3; do echo "$2" > {sysfs}/devices/system/cpu/cpu$c/thermal_throttle/core_throttle_total_time_ms; done
  echo "$3" > {sysfs}/devices/system/cpu/cpu2/thermal_throttle/core_throttle_total_time_ms
}}
set_state 60000 100 100; record_env_sample baseline_rep1_start
set_state 70000 100 100; record_cell_thermal start baseline_28_rep1
set_state 75000 100 140; record_cell_thermal end baseline_28_rep1
check_thermal_safety "baseline target=28 rep=1"
set_state 91000 100 140; record_cell_thermal start scan_28_vus64_rep1
set_state 93000 100 140; record_cell_thermal end scan_28_vus64_rep1
check_thermal_safety "scan target=28 vus=64 rep=1"
"""
    subprocess.run(["bash", "-c", script], check=True)
    return trace


def test_the_parser_reads_the_trace_the_shell_writes(tmp_path):
    trace = thermal.parse_env_trace(str(_shell_trace(tmp_path)))
    assert trace["kind"].tolist() == ["env_sample", "cell_start", "cell_end", "thermal_check",
                                      "cell_start", "cell_end", "thermal_check"]
    checks = trace[trace["kind"] == "thermal_check"]
    assert checks["name"].tolist() == ["baseline target=28 rep=1", "scan target=28 vus=64 rep=1"]
    assert checks["paused_s"].tolist() == [0, 60]
    assert trace.loc[trace["kind"] == "cell_end", "core_throttle"].iloc[0] == {0: 100, 1: 100, 2: 140, 3: 100}
    assert trace["ts"].notna().all()


def test_cell_throttle_is_the_most_throttled_cpu_of_each_service(tmp_path):
    trace = thermal.parse_env_trace(str(_shell_trace(tmp_path)))
    cells = thermal.cell_thermal(trace, lambda cell: {"python": "0-1", "java": "2-3"}).set_index("cell")
    assert cells.loc["baseline_28_rep1", "python_throttle_ms"] == 0
    assert cells.loc["baseline_28_rep1", "java_throttle_ms"] == 40
    assert cells.loc["scan_28_vus64_rep1", "temp_start_c"] == 91
    assert np.isnan(cells.loc["baseline_28_rep1", "pkg_throttle_ms"])


def test_thermal_tables_by_group_and_phase(tmp_path):
    trace = thermal.parse_env_trace(str(_shell_trace(tmp_path)))
    cells = thermal.cell_thermal(trace, lambda cell: {"python": "0-1", "java": "2-3"})
    by_group = thermal.thermal_by_group(cells, results._cell_tier_group, ["python", "java"],
                                        label_of=results._tier_group_label).set_index("Group")
    assert by_group.loc["baseline v28", "Cells throttled on service cores"] == "1/1"
    assert by_group.loc["scan v28", "Max end temp (C)"] == 93
    pauses = thermal.thermal_pauses(trace, results._suite_phase).set_index("Phase")
    assert pauses.loc["scan cells", "Checks that paused"] == 1
    assert pauses.loc["scan cells", "Total paused (min)"] == 1.0
    assert pauses.loc["baseline cells", "Checks that paused"] == 0


def test_thermal_by_group_says_when_counters_are_not_exposed():
    cells = pd.DataFrame({"cell": ["baseline_28_rep1"], "temp_start_c": [60.0], "temp_end_c": [61.0],
                          "pkg_throttle_ms": [np.nan], "python_throttle_ms": [np.nan]})
    table = thermal.thermal_by_group(cells, results._cell_tier_group, ["python"])
    assert table["Cells throttled on service cores"].tolist() == ["not exposed"]


def test_thermal_groups_follow_the_design_order_not_the_run_order():
    cells = pd.DataFrame({"cell": ["scan_mock_vus8_rep1", "baseline_28_rep1", "baseline_mock_rep1",
                                   "scan_calibration_vus8_rep1"],
                          "temp_start_c": [60.0] * 4, "temp_end_c": [61.0] * 4, "pkg_throttle_ms": [0.0] * 4})
    table = thermal.thermal_by_group(cells, results._cell_tier_group, [], label_of=results._tier_group_label,
                                     sort_key=results._tier_group_order)
    assert table["Group"].tolist() == ["baseline mock", "baseline v28", "scan calibration", "scan mock"]


def test_thermal_association_is_taken_within_each_design_cell():
    """Two groups at very different latency with temperatures that track the group,
    not the within-group spread: the design effect must not read as a thermal one."""
    cells = pd.DataFrame({"cell": [f"c{i}" for i in range(8)],
                          "temp_start_c": [60, 61, 62, 63, 80, 81, 82, 83],
                          "temp_end_c": [60, 61, 62, 63, 80, 81, 82, 83],
                          "pkg_throttle_ms": [0.0] * 8})
    latency = pd.DataFrame({"cell": [f"c{i}" for i in range(8)], "group": ["a"] * 4 + ["b"] * 4,
                            "mean_ms": [10.0, 10.1, 9.9, 10.0, 100.0, 99.0, 101.0, 100.0]})
    table = thermal.thermal_latency_association(cells, latency).set_index("Thermal variable")
    assert abs(table.loc["Temperature at cell start (C)", "Spearman rho"]) < 0.5
    assert table.loc["Package throttle during cell (ms)", "p-value"] == "constant"


def test_within_cell_drift_reports_a_consistent_rise():
    rows = []
    for rep in ("1", "2", "3"):
        for i in range(100):
            rows.append({"rep": rep, "time": pd.Timestamp("2026-01-01") + pd.Timedelta(seconds=i),
                         "value": 10.0 if i < 50 else 10.2})
    table = thermal.within_cell_drift([("v28 @ VUS=64", pd.DataFrame(rows))])
    row = table.iloc[0]
    assert row["Mean 2nd-half vs 1st-half change (%)"] == pytest.approx(2.0)
    assert row["Same sign in every cell"] == "yes"


def test_cell_names_and_phases_match_what_the_harness_writes():
    assert results._cell_tier_group("scan_calibration_vus64_rep3") == ("scan", "calibration")
    assert results._cell_tier_group("baseline_28_rep1") == ("baseline", "28")
    assert results._cell_tier_group("calib_28_vus16") is None
    for name, phase in [("warmup_scan_maxvus_rep1 chunk2", "scan warm-up"),
                        ("calib_warmup_scan chunk1", "scan calibration pass"),
                        ("scan calibration target=28", "scan calibration pass"),
                        ("scan_calibration_start", "scan calibration pass"),
                        ("baseline target=mock rep=2", "baseline cells"),
                        ("scan_mock_vus8_rep1", "scan cells")]:
        assert results._suite_phase(name) == phase


def test_analyze_thermal_writes_its_tables_and_warns_on_throttling(tmp_path, capsys):
    _shell_trace(tmp_path)
    metadata = {"cores_used_by_suite": {"python_service_cpuset": "0-1", "transaction_service_cpuset": "2-3",
                                        "k6_cpuset": "unknown"}}
    latency = pd.DataFrame({"cell": ["baseline_28_rep1", "scan_28_vus64_rep1"],
                            "group": ["28", "28@64"], "mean_ms": [5.0, 50.0]})
    results.analyze_thermal(str(tmp_path), str(tmp_path / "out"), metadata, latency)
    tables = tmp_path / "out" / "tables"
    for name in ("table8a_thermal_by_group", "table8b_thermal_pauses", "table8c_thermal_latency_association"):
        assert (tables / f"{name}.csv").exists()
    assert (tmp_path / "out" / "figures" / "figure8_thermal_timeline.png").exists()
    assert "Max k6 core throttle (ms)" not in pd.read_csv(tables / "table8a_thermal_by_group.csv").columns
    assert "1/2 measured cell(s) were thermally throttled" in capsys.readouterr().out


def test_analyze_thermal_skips_a_trace_without_cell_samples(tmp_path, capsys):
    (tmp_path / "env_trace_log.txt").write_text(
        "env_sample label=baseline_rep1_start ts=2026-09-21T09:53:39Z governor=performance freqs_khz=cpu0=1\n")
    results.analyze_thermal(str(tmp_path), str(tmp_path), {}, None)
    assert "no per-cell samples" in capsys.readouterr().out


# --- the ablation's outcome tally, control and planned comparison ---

def _ablation_cell(path, n_ok, n_failed=0, n_timeout=0, dropped=0, dispatch=5.0, gz=True):
    m = ablation.CELL_FILE_RE.match(path.name)
    tags = {"phase": "ablation", "arm": m.group("arm"), "arm_value": m.group("value"), "rep": m.group("rep")}
    lines = []
    for status, n in (("200", n_ok), ("502", n_failed), ("0", n_timeout)):
        for _ in range(n):
            lines.append(_point("http_req_duration", 50.0, dict(tags, status=status)))
    for _ in range(n_ok):
        lines.append(_point("python_thread_dispatch_time_ms", dispatch, dict(tags, status="200")))
        lines.append(_point("python_total_time_ms", dispatch + 3, dict(tags, status="200")))
    lines += [_point("dropped_iterations", 1.0, {"scenario": "run"})] * dropped
    text = "\n".join(lines) + "\n"
    if gz:
        with gzip.open(path, "wt") as f:
            f.write(text)
    else:
        path.write_text(text)


def test_ablation_tally_counts_every_outcome_before_sampling(tmp_path):
    _ablation_cell(tmp_path / "ablation_cpuset_0-1_rep1.json.gz", n_ok=40, n_failed=3, n_timeout=2, dropped=5)
    _ablation_cell(tmp_path / "ablation_cpuset_0-1_rep2.json", n_ok=10, gz=False)
    df, counts = ablation.load_ablation_cells(str(tmp_path))
    table = ablation.build_error_table(counts)
    row = table.iloc[0]
    assert (row["N reps"], row["Total Requests"], row["Successful (200)"]) == (2, 55, 50)
    assert (row["HTTP Errors (non-200 response)"], row["Timeouts / Network Errors (no response)"]) == (3, 2)
    assert row["Dropped iterations"] == 5
    assert row["Error Rate (%)"] == pytest.approx(round(100 * 5 / 55, 2))
    decomposition = ablation.build_decomposition_table(df, counts)
    assert decomposition["N requests (HTTP 200, pooled)"].tolist() == [50]


def test_ablation_loader_keeps_what_a_truncated_gzip_decompressed(tmp_path, capsys):
    whole = tmp_path / "ablation_workers_1_rep1.json.gz"
    _ablation_cell(whole, n_ok=20000)
    whole.write_bytes(whole.read_bytes()[: whole.stat().st_size // 2])
    df, _ = ablation.load_ablation_cells(str(tmp_path))
    assert 0 < int((df["metric"] == "python_thread_dispatch_time_ms").sum()) < 20000
    assert "compressed stream ended early" in capsys.readouterr().out


def test_ablation_controls_come_from_the_run_metadata():
    recorded = {"ablation_config": {"control_values": {"thread_limiter": "32", "cpuset": "0-3", "workers": "2"}}}
    assert ablation.control_cells(recorded) == {"thread_limiter": "32", "cpuset": "0-3", "workers": "2"}
    assert ablation.control_cells({}) == ablation.CONTROL_CELL


@pytest.mark.parametrize("values,control,extreme", [
    (["0-1", "0-1,4-5,8-9", "0-1,4-5,8-9,12-13"], "0-1,4-5,8-9", "0-1"),
    (["40", "64", "128"], "40", "128"),
    (["1", "2", "3"], "3", "1"),
    (["2", "4", "6"], "4", "6"),
])
def test_the_extreme_is_the_value_farthest_from_control(values, control, extreme):
    """For a mid-sweep control the farther value is the arm's largest manipulation
    (2 of 6 CPUs, not 8); an exact tie goes to the later sweep value."""
    assert ablation._extreme_value(values, control) == extreme


def test_control_vs_extreme_uses_the_recorded_control(tmp_path):
    for value, dispatch in (("1", 9.0), ("2", 6.0), ("3", 5.0)):
        for rep in range(1, 5):
            _ablation_cell(tmp_path / f"ablation_workers_{value}_rep{rep}.json.gz", n_ok=20,
                           dispatch=dispatch + rep * 0.01)
    df, _ = ablation.load_ablation_cells(str(tmp_path))
    row = ablation.control_vs_extreme_test(df, controls={"workers": "2"}).iloc[0]
    assert (row["Control"], row["Extreme"]) == ("2", "3")


def _run_ablation_main(results_dir, output_dir):
    return subprocess.run([sys.executable, str(ANALYSIS_DIR / "analyze-ablation.py"),
                           "--results-dir", str(results_dir), "--output-dir", str(output_dir)],
                          capture_output=True, text=True)


def test_analyze_ablation_exits_non_zero_on_a_failed_run_or_no_data(tmp_path):
    empty = _run_ablation_main(tmp_path, tmp_path / "out")
    assert empty.returncode == 1 and "No usable ablation" in empty.stdout

    _ablation_cell(tmp_path / "ablation_workers_1_rep1.json.gz", n_ok=20)
    (tmp_path / "ablation_run_failures_log.txt").write_text("[FATAL] [smt] overlap\n")
    failed = _run_ablation_main(tmp_path, tmp_path / "out")
    assert failed.returncode == 1 and "has entries" in failed.stdout
