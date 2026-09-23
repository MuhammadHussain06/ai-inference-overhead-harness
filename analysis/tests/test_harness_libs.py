"""Guards the Python halves of the load-testing harness: lib/warmup_gate.py, the
warm-up criterion the live gate and table0 share, and lib/k6_filter.py, which
decides what every result file keeps."""

import gzip
import importlib.util
import json
import statistics
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

LIB_DIR = Path(__file__).resolve().parents[2] / "load-testing" / "lib"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, LIB_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = _load("warmup_gate")
k6_filter = _load("k6_filter")

T0 = datetime(2026, 1, 1, tzinfo=timezone.utc)


def _ts(ms):
    return (T0 + timedelta(milliseconds=ms)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _points(values, step_ms=10.0, start_ms=0.0, retain=(gate.HEAD_RETAIN, gate.TAIL_RETAIN)):
    points = gate.TierPoints(*retain)
    for i, v in enumerate(values):
        points.add(_ts(start_ms + i * step_ms), float(v))
    return points


def _line(metric, value, t, tier="28", status="200", phase="warmup"):
    return json.dumps({"metric": metric, "type": "Point",
                       "data": {"time": t, "value": value,
                                "tags": {"tier": tier, "status": status, "phase": phase}}},
                      separators=(",", ":"))


# timestamps

def test_ts_key_orders_go_trimmed_fractions_numerically():
    """Go drops trailing zeros from the fraction, and the '.' for a whole second."""
    stamps = ["2026-01-01T00:00:07.5Z", "2026-01-01T00:00:07Z", "2026-01-01T00:00:07.05Z",
              "2026-01-01T00:00:07.500000001Z"]
    assert sorted(stamps) != sorted(stamps, key=gate.ts_key)
    assert sorted(stamps, key=gate.ts_key) == [stamps[1], stamps[2], stamps[0], stamps[3]]


def test_ts_seconds_keeps_the_sub_microsecond_fraction_and_applies_the_offset():
    """datetime truncates to microseconds; the gate's window spans must not."""
    whole = gate.ts_seconds("2026-01-01T00:00:01Z")
    assert gate.ts_seconds("2026-01-01T00:00:01.0000009Z") - whole == pytest.approx(9e-7, abs=3e-7)
    assert gate.ts_seconds("2026-01-01T01:00:01+01:00") == pytest.approx(whole)


# the time-defined window

def test_window_stays_at_the_base_when_it_already_spans_the_minimum():
    tail = [(_ts(i * 10), 1.0) for i in range(2000)]   # 500 requests = 5s
    assert gate.effective_window(tail, 500, 3.0) == 500


def test_window_grows_in_base_steps_until_it_spans_the_minimum():
    tail = [(_ts(i), 1.0) for i in range(20000)]        # 1000 req/s
    # The last 3000 requests span 2.999s, so 3500 is the first multiple that reaches 3s.
    assert gate.effective_window(tail, 500, 3.0) == 3500


def test_window_exceeds_the_tail_when_the_tail_cannot_span_it():
    tail = [(_ts(i), 1.0) for i in range(1200)]
    assert gate.effective_window(tail, 500, 3.0) > len(tail)


def test_a_zero_minimum_span_is_the_fixed_count_window():
    tail = [(_ts(i), 1.0) for i in range(20000)]
    assert gate.effective_window(tail, 500, 0) == 500


# the verdict

def test_no_points_at_all_is_reported_as_no_requests():
    assert gate.evaluate(None)["status"] == "no requests"


def test_only_failed_requests_never_converge():
    points = gate.TierPoints()
    points.n_failed = 40
    v = gate.evaluate(points)
    assert v["status"] == "no HTTP 200 responses" and not v["converged"] and v["n_failed"] == 40


def test_fewer_than_three_windows_is_not_read_as_no_drift():
    v = gate.evaluate(_points([5.0] * 1499))
    assert v["status"] == "fewer than three windows" and not v["converged"]
    assert gate.evaluate(_points([5.0] * 1500))["status"] == "converged"


def test_drift_on_both_bounds_is_reported_with_its_size():
    v = gate.evaluate(_points([10.0] * 1000 + [20.0] * 500))
    assert v["status"] == "drifting"
    assert v["tail_drift_pct"] == pytest.approx(100.0)
    assert v["total_drift_pct"] == pytest.approx(100.0)
    assert v["window_span_s"] == pytest.approx(4.99)


def test_window_medians_are_true_medians():
    """An even-sized window's median is the mean of its middle two, the statistic
    the table reports."""
    values = [1.0] * 250 + [3.0] * 250
    v = gate.evaluate(_points(values * 3))
    assert v["last_p50"] == statistics.median(values) == 2.0


def test_the_window_is_held_to_what_was_retained():
    """Above the retention bound the tail no longer holds two time-defined windows,
    so the window shrinks to what it does hold rather than reading across a gap."""
    points = _points([5.0] * 5000, step_ms=1.0, retain=(1000, 2000))
    v = gate.evaluate(points, base_window=500, min_span_s=3.0)
    assert v["window"] == 1000 and v["status"] == "converged"


# reading a result file

def test_read_points_splits_outcomes_and_skips_what_is_not_a_latency_point(tmp_path):
    path = tmp_path / "warmup.json"
    path.write_text("\n".join([
        _line("http_req_duration", 5.0, _ts(0)),
        _line("http_req_duration", 900.0, _ts(1), status="0"),
        _line("http_req_blocked", 0.1, _ts(2)),
        "not json with \"http_req_duration\" in it",
        json.dumps({"metric": "http_req_duration", "type": "Point",
                    "data": {"time": _ts(3), "value": 1.0, "tags": {"status": "200"}}}),
    ]) + "\n")
    tiers, truncated = gate.read_points(str(path))
    assert not truncated
    assert list(tiers) == ["28"]
    assert (tiers["28"].n_ok, tiers["28"].n_failed) == (1, 1)


def test_a_truncated_gzip_keeps_what_decompressed_and_says_so(tmp_path):
    whole = tmp_path / "whole.json.gz"
    with gzip.open(whole, "wt") as f:
        for i in range(20000):
            f.write(_line("http_req_duration", 5.0, _ts(i)) + "\n")
    cut = tmp_path / "cut.json.gz"
    cut.write_bytes(whole.read_bytes()[: whole.stat().st_size // 2])
    tiers, truncated = gate.read_points(str(cut))
    assert truncated
    assert 0 < tiers["28"].n_ok < 20000


def test_expected_targets_come_first_and_are_reported_even_when_absent(tmp_path):
    path = tmp_path / "warmup.json"
    path.write_text("\n".join(_line("http_req_duration", 5.0, _ts(i * 10)) for i in range(1500)) + "\n")
    verdicts, _ = gate.evaluate_file(str(path), expect=["mock", "28"])
    assert list(verdicts) == ["mock", "28"]
    assert verdicts["mock"]["status"] == "no requests"
    assert verdicts["28"]["status"] == "converged"


def test_the_cli_passes_only_when_every_expected_target_converged(tmp_path):
    path = tmp_path / "warmup.json"
    path.write_text("\n".join(_line("http_req_duration", 5.0, _ts(i * 10)) for i in range(1500)) + "\n")

    def run(expect):
        return subprocess.run(
            [sys.executable, str(LIB_DIR / "warmup_gate.py"), str(path), "--expect", expect, "--label", "chunk1"],
            capture_output=True, text=True, check=True)

    ok = run("28")
    assert ok.stdout.strip() == "true"
    assert "[warmup-gate] chunk1: tier=28 n=1500 window=500 (5.0s)" in ok.stderr
    assert run("28 mock").stdout.strip() == "false"


# k6_filter

KEEP = {"http_req_duration", "python_total_time_ms"}


def _reference(line, keep):
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return False
    return isinstance(obj, dict) and obj.get("type") == "Point" and obj.get("metric") in keep


@pytest.mark.parametrize("line", [
    _line("http_req_duration", 5.0, _ts(0)),
    _line("http_req_duration_extra", 5.0, _ts(0)),
    _line("http_req_blocked", 0.1, _ts(0)),
    _line("python_total_time_ms", 1.0, _ts(0)),
    json.dumps({"metric": "http_req_duration", "type": "Metric",
                "data": {"name": "http_req_duration", "type": "trend", "contains": "time",
                         "thresholds": [], "submetrics": None}}, separators=(",", ":")),
    json.dumps({"type": "Point", "metric": "http_req_duration",
                "data": {"time": _ts(0), "value": 1, "tags": {}}}),
    json.dumps({"metric": 'odd"name', "type": "Point", "data": {"time": _ts(0), "value": 1, "tags": {}}},
               separators=(",", ":")),
    '{"metric":"http_req_duration","type":"Point","data":{"time":"2026-01-01T00:00:00Z","val',
    "[]",
    "not json",
])
def test_the_fast_path_agrees_with_a_full_parse(line):
    assert k6_filter.kept(line, KEEP) == _reference(line, KEEP)


def _run_filter(*args):
    subprocess.run([sys.executable, str(LIB_DIR / "k6_filter.py"), *args], check=True)


def test_finalize_and_append_keep_exactly_the_listed_points(tmp_path):
    raw = tmp_path / "raw.json"
    lines = [_line("http_req_duration", 5.0, _ts(0)), _line("vus", 5, _ts(0)),
             _line("python_total_time_ms", 1.0, _ts(1)), "", "garbage"]
    raw.write_text("\n".join(lines) + "\n")
    _run_filter("finalize", str(raw), str(tmp_path / "out.json.gz"), ",".join(sorted(KEEP)))
    with gzip.open(tmp_path / "out.json.gz", "rt") as f:
        assert f.read().splitlines() == [lines[0], lines[2]]

    plain = tmp_path / "combined.json"
    _run_filter("append", str(raw), str(plain), "http_req_duration")
    _run_filter("append", str(raw), str(plain), "http_req_duration")
    assert plain.read_text().splitlines() == [lines[0], lines[0]]


def test_gzip_mode_compresses_byte_for_byte(tmp_path):
    plain = tmp_path / "combined.json"
    plain.write_text("".join(_line("http_req_duration", i, _ts(i)) + "\n" for i in range(1000)))
    _run_filter("gzip", str(plain), str(tmp_path / "out.json.gz"))
    with gzip.open(tmp_path / "out.json.gz", "rb") as f:
        assert f.read() == plain.read_bytes()
