"""Guards the analysis helpers that shape every reported table and figure."""

import importlib.util
import inspect
import json
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

# --- warm-up convergence criterion (table0) ---

# The criterion is the looser of two bounds, so the column header has to name both --
# a reader cannot otherwise tell which one admitted a given window.
CONVERGED_COL = "Converged (tail <5% or <0.25ms)"
WINDOW = 500


def _shell_const(script, name):
    """Reads a top-level constant out of a load-testing script's text."""
    text = (LOAD_TESTING_DIR / script).read_text()
    return re.search(rf"^{name}=(\S+)$", text, re.M).group(1)


def _warmup_frame(segments, tier="28", source_file="warmup_scan_rep1"):
    """A phase='warmup' frame whose HTTP 200 latencies run through `segments`
    ((value, count) pairs) in time order."""
    values, times = [], []
    base = pd.Timestamp("2026-01-01T00:00:00Z")
    for value, count in segments:
        for _ in range(count):
            times.append(base + pd.Timedelta(milliseconds=len(times)))
            values.append(value)
    return pd.DataFrame({"phase": "warmup", "metric": "http_req_duration",
                         "value": values, "status": "200", "tier": tier,
                         "source_file": source_file, "time": times})


def _warmup_table(df, tmp_path):
    results.analyze_warmup(df, str(tmp_path))
    return pd.read_csv(tmp_path / "tables" / "table0_warmup_convergence_check.csv")


def test_warmup_criterion_matches_the_live_shell_gate():
    """table0 claims to report the verdict run-suite.sh's gate acted on. If the two
    drift apart, the table says a window converged that warm-up never stopped for."""
    for script in ("run-suite.sh", "run-ablation.sh"):
        assert int(_shell_const(script, "WARMUP_WINDOW")) == WINDOW
        assert float(_shell_const(script, "WARMUP_TAIL_TOLERANCE_PCT")) == 5.0
        assert float(_shell_const(script, "WARMUP_TAIL_ABS_FLOOR_MS")) == 0.25

    for fn in (results.analyze_warmup, ablation.build_ablation_warmup_table):
        params = inspect.signature(fn).parameters
        assert params["window_size"].default == WINDOW
        assert params["tail_tolerance_pct"].default == 5.0
        assert params["tail_abs_floor_ms"].default == 0.25


def test_warmup_converges_within_the_percentage_tolerance(tmp_path):
    table = _warmup_table(_warmup_frame([(100.0, 2 * WINDOW), (102.0, WINDOW)]), tmp_path)
    assert table[CONVERGED_COL].tolist() == ["YES"]
    assert table["Tail drift (%)"].iloc[0] == pytest.approx(2.0)


def test_warmup_converges_on_the_absolute_floor_the_percentage_bound_rejects(tmp_path):
    """5% of a sub-millisecond round trip is a few dozen microseconds -- inside
    ordinary timer jitter, so a percentage-only bound never clears the fast tiers."""
    table = _warmup_table(_warmup_frame([(0.20, 2 * WINDOW), (0.40, WINDOW)]), tmp_path)
    assert table[CONVERGED_COL].tolist() == ["YES"]
    # 100% tail drift: only the 0.20 ms absolute gap could have admitted this window.
    assert table["Tail drift (%)"].iloc[0] == pytest.approx(100.0)


def test_warmup_reports_no_when_both_bounds_are_exceeded(tmp_path, capsys):
    table = _warmup_table(_warmup_frame([(10.0, 2 * WINDOW), (20.0, WINDOW)]), tmp_path)
    assert table[CONVERGED_COL].tolist() == ["no"]
    assert table["Tail drift (%)"].iloc[0] == pytest.approx(100.0)
    out = capsys.readouterr().out
    assert "1/1 warm-up windows had not converged" in out


def test_warmup_reports_a_lagging_target_separately_from_a_settled_one(tmp_path):
    """Per-target rows, not one pooled verdict: a tier still moving must stay visible
    next to the tiers that settled, which is the same grouping the live gate applies."""
    df = pd.concat([_warmup_frame([(0.50, 3 * WINDOW)], tier="mock"),
                    _warmup_frame([(10.0, 2 * WINDOW), (20.0, WINDOW)], tier="28")])
    table = _warmup_table(df, tmp_path).set_index("Tier")
    assert table.loc["mock", CONVERGED_COL] == "YES"
    assert table.loc["v28", CONVERGED_COL] == "no"


def test_warmup_needs_three_full_windows_before_reporting(tmp_path, capsys):
    """One point short of 3 * window_size leaves no penultimate window to compare
    against; reporting that as converged would read "not measured" as "no drift"."""
    results.analyze_warmup(_warmup_frame([(10.0, 3 * WINDOW - 1)]), str(tmp_path))
    assert "Skipping empty table" in capsys.readouterr().out
    assert not (tmp_path / "tables" / "table0_warmup_convergence_check.csv").exists()

    table = _warmup_table(_warmup_frame([(10.0, 3 * WINDOW)]), tmp_path)
    assert table["N Requests"].tolist() == [3 * WINDOW]


def test_warmup_table_names_the_criterion_it_applied(tmp_path):
    table = _warmup_table(_warmup_frame([(10.0, 3 * WINDOW)]), tmp_path)
    assert CONVERGED_COL in table.columns
    assert f"Prev {WINDOW} P50 (ms)" in table.columns
    caption = (tmp_path / "tables" / "table0_warmup_convergence_check.tex").read_text()
    assert "whichever bound is looser" in caption
    assert "under 5% or an absolute gap under 0.25 ms" in caption


def _ablation_warmup_file(path, segments):
    """ablation_warmup_<arm>_<value>_rep<N>.json, as run-ablation.sh names it."""
    lines, i = [], 0
    for value, count in segments:
        for _ in range(count):
            lines.append(json.dumps({"type": "Point", "metric": "http_req_duration", "data": {
                "time": f"2026-01-01T00:00:00.{i:06d}Z", "value": value,
                "tags": {"tier": "28", "status": "200"}}}))
            i += 1
    path.write_text("\n".join(lines) + "\n")


def test_ablation_warmup_table_applies_the_same_two_bound_criterion(tmp_path):
    """run-ablation.sh keeps its own copy of the gate, so this table has to agree with
    analyze-results.py's on both bounds and on the column that names them."""
    _ablation_warmup_file(tmp_path / "ablation_warmup_cpuset_0-1_rep1.json",
                          [(0.20, 2 * WINDOW), (0.40, WINDOW)])
    _ablation_warmup_file(tmp_path / "ablation_warmup_cpuset_2-3_rep1.json",
                          [(10.0, 2 * WINDOW), (20.0, WINDOW)])
    table = ablation.build_ablation_warmup_table(str(tmp_path)).set_index("Value")
    assert CONVERGED_COL in table.columns
    assert table.loc["0-1", CONVERGED_COL] == "YES"
    assert table.loc["2-3", CONVERGED_COL] == "no"


def test_ablation_warmup_table_needs_three_full_windows(tmp_path, capsys):
    _ablation_warmup_file(tmp_path / "ablation_warmup_cpuset_0-1_rep1.json",
                          [(10.0, 3 * WINDOW - 1)])
    assert ablation.build_ablation_warmup_table(str(tmp_path)).empty
    assert f"none had >= {3 * WINDOW} HTTP 200 requests" in capsys.readouterr().out


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
    files cannot shift that fixture's already-asserted point counts. Carries an
    oversized scan_ file with 50 non-200 points mixed into the sampled ones, and an
    equally oversized warmup_-prefixed file, for the two subsampling exemptions that
    fixture doesn't cover."""
    d = tmp_path_factory.mktemp("oversized_exemptions")
    _sampled_file(d / "scan_28_vus64_rep1.json", MAX_POINTS_PER_FILE + 1000, n_errors=50)
    _sampled_file(d / "warmup_baseline_rep1.json", MAX_POINTS_PER_FILE + 1000)
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


def test_load_results_keeps_every_warmup_point_regardless_of_the_cap(oversized_results_dir_exemptions, capsys):
    """converge_warmup()'s tail-window check needs a genuinely contiguous, time-ordered
    tail; random subsampling would break that, so warmup_* files are exempt from the
    reservoir entirely, no matter how large."""
    df, _ = results.load_results(str(oversized_results_dir_exemptions), prefixes=("warmup_",))
    assert int((df["metric"] == "http_req_duration").sum()) == MAX_POINTS_PER_FILE + 1000
    assert "subsampled" not in capsys.readouterr().out


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
    those same timestamps, one point for each of extra_metrics -- reproducing the
    real shape that under-filled the reservoir: several metrics sharing one point
    budget per file, none of them individually near the cap."""
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
    """Reproduces the actual bug: one metric's own point count stays under
    MAX_POINTS_PER_FILE, but several metrics sharing that file's single reservoir
    push the combined total over it, so http_req_duration itself gets subsampled
    and _throughput_reqs_per_s()'s (n-1)/span reads out at roughly the subsampling
    ratio instead of the metric's own true rate."""
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
    previously returned with no message at all -- indistinguishable from a real,
    passing cross-check."""
    df = pd.DataFrame({"phase": [], "metric": [], "value": []})
    results.crosscheck_error_counters(df, "scan", ["tier"], lambda k: str(k[0]), None)
    assert "did not run for this phase" in capsys.readouterr().out


def test_analyze_measurement_floor_warns_when_the_floor_tier_has_no_rows(tmp_path, capsys):
    """floor_tier listed in the run's order but producing zero rows (e.g. a failed
    calibration cell) previously returned silently instead of explaining why
    table1e is absent."""
    e2e = pd.DataFrame({"tier": ["5", "5"], "value": [10.0, 12.0]})
    results.analyze_measurement_floor(e2e, ["calibration", "5"], str(tmp_path))
    assert "no valid values" in capsys.readouterr().out


def test_analyze_gc_logs_warns_when_a_rep_has_no_parsable_records(tmp_path, capsys):
    """A gc log with zero parsable lines produces a NaN gc_overhead_pct that fails the
    ">1.0" comparison silently -- previously indistinguishable from a rep that was
    fully parsed and genuinely under 1%."""
    gc_dir = tmp_path / "gc-logs"
    gc_dir.mkdir()
    (gc_dir / "gc_baseline_rep1.log").write_text("")
    results.analyze_gc_logs(str(tmp_path), str(tmp_path))
    out = capsys.readouterr().out
    assert "no measurable GC overhead" in out
    assert "<=1% of wall-clock time in all reps" not in out
