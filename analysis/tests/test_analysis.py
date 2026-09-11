"""Guards the analysis helpers that shape every reported table and figure."""

import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ANALYSIS_DIR = Path(__file__).resolve().parents[1]


def _load(module_name, filename):
    """Imports a hyphenated script by path; neither is importable as a package."""
    spec = importlib.util.spec_from_file_location(module_name, ANALYSIS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


results = _load("analyze_results", "analyze-results.py")
ablation = _load("analyze_ablation", "analyze-ablation.py")


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

def test_scan_levels_keep_non_default_concurrency_values():
    """A CONCURRENCY_OVERRIDE outside CONCURRENCY_ORDER must not drop those cells."""
    seen = [2, 6, 12]
    levels = ([v for v in results.CONCURRENCY_ORDER if v in seen]
              + [v for v in seen if v not in results.CONCURRENCY_ORDER])
    assert sorted(levels) == sorted(seen)


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
    assert window_s == pytest.approx(59.488)


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
    df = results.load_results(str(tmp_path), prefixes=("scan_",))
    assert len(df) == 2
    assert set(df["metric"]) == {"http_req_duration", "python_model_inference_time_ms"}
    assert df["vus"].tolist() == [64, 64]
    assert df["rep"].tolist() == ["3", "3"]


def test_load_results_returns_none_when_no_file_matches_the_prefix(tmp_path):
    (tmp_path / "baseline_28_rep1.json").write_text(_point("http_req_duration", 1.0, {"tier": "28"}) + "\n")
    assert results.load_results(str(tmp_path), prefixes=("scan_",)) is None


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
    df = results.load_results(str(tmp_path), prefixes=("scan_",))
    table = results.error_summary(df, "scan", ["tier"], lambda k: results._tier_label(k[0]))
    row = table.iloc[0]
    assert row["Total Requests"] == 10
    assert row["Successful (200)"] == 7
    assert row["HTTP Errors (non-200 response)"] == 2
    assert row["Timeouts / Network Errors (no response)"] == 1
    assert row["Error Rate (%)"] == pytest.approx(30.0)


# --- GC log parsing, effect size, and throughput edge cases ---

SERIAL_PAUSE_LOG = (
    "[2026-01-01T12:00:00.000+0000][0.005s][info][gc     ] Using Serial\n"
    "[2026-01-01T12:00:00.100+0000][0.105s][info][gc          ] "
    "GC(0) Pause Young (Allocation Failure) 18M->2M(61M) 1.146ms\n"
)


def test_parse_gc_log_warns_when_a_non_g1_collector_produced_parsable_pauses(tmp_path, capsys):
    """Serial/Parallel/Shenandoah emit the same generic "GC(N) Pause ..." record as G1.

    Verified on JDK 21.0.10: their pauses parse cleanly, so checking the collector only in
    the zero-pause branch reported them as G1's with no warning at all.
    """
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


def test_between_run_sd_is_not_estimable_from_one_rep():
    """0.0 would read as perfect consistency rather than "not estimable"."""
    one = pd.DataFrame([{"metric": "m", "phase": "baseline", "tier": "v5",
                         "rep": "1", "value": 10.0}])
    out = results.between_run_consistency(one, "m", "baseline", ["tier"], lambda k: k[0])
    assert np.isnan(out["StdDev Across Reps (ms)"].iloc[0])


def test_warmup_skip_distinguishes_absent_data_from_a_failed_warmup(tmp_path, capsys):
    df = pd.DataFrame([{"phase": "warmup", "metric": "http_req_duration", "value": 5.0,
                        "status": "500", "tier": "v28", "source_file": "warmup_baseline_rep1",
                        "time": pd.Timestamp("2026-01-01T00:00:00Z"), "rep": "1"}])
    results.analyze_warmup(df, str(tmp_path))
    out = capsys.readouterr().out
    assert "none returned HTTP 200" in out and "run without" not in out