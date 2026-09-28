"""Guards the Python halves of the load-testing harness: lib/warmup_gate.py, the
warm-up criterion the live gate and table0 share; lib/k6_filter.py, which decides
what every result file keeps; lib/placement.py, which records connection-to-worker
placement; lib/cpufreq_sampler.py, which records each cell's service-core clock and
catches a loss of mains power; and lib/openloop_rates.py, which sets the open-loop
arrival rates."""

import gzip
import importlib.util
import json
import statistics
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

LIB_DIR = Path(__file__).resolve().parents[2] / "load-testing" / "lib"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, LIB_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sys.path.insert(0, str(LIB_DIR))
gate = _load("warmup_gate")
k6_filter = _load("k6_filter")
placement = _load("placement")
openloop_rates = _load("openloop_rates")
cpufreq_sampler = _load("cpufreq_sampler")

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


# lib/placement.py

def _fake_proc(root, established_by_pid, extra_listen_holders=()):
    """A procfs tree like a uvicorn container's: sh (100) -> supervisor (101) ->
    workers 102-104 plus a resource tracker (105). Every uvicorn process holds the
    listening socket (inode 900); established_by_pid gives each process's accepted
    connections as socket inodes."""
    tree = {100: (1, "sh"), 101: (100, "uvicorn app"), 102: (101, "python (w)"), 103: (101, "python"),
            104: (101, "python"), 105: (101, "python"), 999: (1, "unrelated")}
    listen_holders = {101, 102, 103, 104, *extra_listen_holders}
    lines = ["  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"]
    lines.append("   0: 00000000:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 900")
    for pid, inodes in established_by_pid.items():
        for inode in inodes:
            lines.append(f"   1: 0200000A:1F40 0300000A:D431 01 00000000:00000000 00:00000000 00000000  1000 0 {inode}")
    lines.append("   2: 0200000A:9C40 0300000A:1F90 01 00000000:00000000 00:00000000 00000000  1000 0 950")
    for pid, (ppid, comm) in tree.items():
        d = root / str(pid)
        (d / "fd").mkdir(parents=True)
        (d / "stat").write_text(f"{pid} ({comm}) S {ppid} {pid} {pid} 0 -1\n")
        (d / "status").write_text(f"Name:\tx\nNSpid:\t{pid}\t{pid - 93}\n")
        sockets = (["900"] if pid in listen_holders else []) + list(established_by_pid.get(pid, []))
        for fd, inode in enumerate(sockets, start=3):
            (d / "fd" / str(fd)).symlink_to(f"socket:[{inode}]")
        (d / "fd" / "0").symlink_to("/dev/null")
    (root / "100" / "net").mkdir()
    (root / "100" / "net" / "tcp").write_text("\n".join(lines) + "\n")
    return root


def test_placement_finds_the_workers_not_the_supervisor_or_tracker(tmp_path):
    root = _fake_proc(tmp_path, {})
    assert placement.find_workers(str(root), 100, 8000) == [102, 103, 104]


def test_placement_counts_connections_per_worker_by_namespace_pid(tmp_path):
    root = _fake_proc(tmp_path, {102: ["901", "902"], 104: ["903"]})
    workers = placement.find_workers(str(root), 100, 8000)
    assert placement.snapshot(str(root), 100, 8000, workers) == (3, {9: 2, 10: 0, 11: 1})


def test_placement_single_process_server_is_its_own_worker(tmp_path):
    root = _fake_proc(tmp_path, {101: ["901"]})
    for pid in (102, 103, 104):
        for link in (root / str(pid) / "fd").iterdir():
            link.unlink()
    assert placement.find_workers(str(root), 100, 8000) == [101]


def test_placement_sampler_logs_changes_and_stops_on_sigterm(tmp_path):
    root = _fake_proc(tmp_path, {102: ["901", "902"]})
    proc = subprocess.Popen([sys.executable, str(LIB_DIR / "placement.py"), "--container-pid", "100",
                             "--cell", "scan_10_vus2_rep4", "--proc-root", str(root), "--interval", "0.05"],
                            stdout=subprocess.PIPE, text=True)
    time.sleep(0.5)
    proc.terminate()
    out = proc.communicate(timeout=5)[0].splitlines()
    assert proc.returncode == 0
    assert len(out) == 2
    assert out[0].startswith("placement cell=scan_10_vus2_rep4 ts=")
    assert out[0].endswith("established=2 workers=9:2,10:0,11:0")
    assert out[1].startswith("placement_end cell=scan_10_vus2_rep4 ts=")


def test_placement_reports_unavailable_instead_of_failing(tmp_path):
    proc = subprocess.run([sys.executable, str(LIB_DIR / "placement.py"), "--container-pid", "4242",
                           "--cell", "c", "--proc-root", str(tmp_path)], capture_output=True, text=True, timeout=10)
    assert proc.returncode == 0
    assert proc.stdout.startswith("placement_unavailable cell=c ")


# lib/cpufreq_sampler.py

def _clock_host(tmp_path, busy, khz, mains="1", ticks=1000):
    """A sysfs and procfs pair: per-CPU busy jiffies (out of ticks total) and clocks."""
    sysfs, proc = tmp_path / "sys", tmp_path / "proc"
    (sysfs / "class/power_supply/ADP1").mkdir(parents=True, exist_ok=True)
    (sysfs / "class/power_supply/ADP1/type").write_text("Mains\n")
    (sysfs / "class/power_supply/ADP1/online").write_text(mains + "\n")
    proc.mkdir(exist_ok=True)
    for cpu, value in enumerate(khz):
        freq = sysfs / f"devices/system/cpu/cpu{cpu}/cpufreq"
        freq.mkdir(parents=True, exist_ok=True)
        (freq / "scaling_cur_freq").write_text(f"{value}\n")
    stat = ["cpu  0 0 0 0 0 0 0 0"] + [f"cpu{c} {b} 0 0 {ticks - b} 0 0 0 0" for c, b in enumerate(busy)]
    (proc / "stat").write_text("\n".join(stat) + "\n")
    return sysfs, proc


def _start_clock_sampler(sysfs, proc, *cpus):
    args = [sys.executable, str(LIB_DIR / "cpufreq_sampler.py"), "--cell", "scan_28_vus64_rep1",
            "--interval", "0.05", "--sysfs-root", str(sysfs), "--proc-root", str(proc)]
    for pair in cpus:
        args += ["--cpus", pair]
    return subprocess.Popen(args, stdout=subprocess.PIPE, text=True)


def _fields(line):
    return dict(tok.split("=", 1) for tok in line.split() if "=" in tok)


def test_clock_sampler_weights_each_cpu_by_its_busy_time(tmp_path):
    sysfs, proc = _clock_host(tmp_path, busy=[0, 0, 0], khz=[800000, 800000, 800000])
    sampler = _start_clock_sampler(sysfs, proc, "python=0-1", "k6=2")
    time.sleep(0.2)
    # Over 1000 jiffies: cpu0 busy 300 at 1000 MHz, cpu1 busy 100 at 2200 MHz, cpu2 idle.
    _clock_host(tmp_path, busy=[300, 100, 0], khz=[1000000, 2200000, 800000], ticks=2000)
    time.sleep(0.3)
    sampler.terminate()
    line = sampler.communicate(timeout=5)[0].strip()
    assert sampler.returncode == 0
    assert line.startswith("cell_freq ts=") and line.endswith(" cell=scan_28_vus64_rep1")
    fields = _fields(line)
    assert fields["python_mhz"] == "1300" and fields["python_busy_pct"] == "20.0"
    assert fields["k6_mhz"] == "na" and fields["k6_busy_pct"] == "0.0"
    assert fields["mains_offline_samples"] == "0"


def test_clock_sampler_exits_3_when_mains_power_is_lost(tmp_path):
    sysfs, proc = _clock_host(tmp_path, busy=[0], khz=[800000])
    sampler = _start_clock_sampler(sysfs, proc, "python=0")
    time.sleep(0.15)
    (sysfs / "class/power_supply/ADP1/online").write_text("0\n")
    time.sleep(0.2)
    (sysfs / "class/power_supply/ADP1/online").write_text("1\n")
    time.sleep(0.1)
    sampler.terminate()
    line = sampler.communicate(timeout=5)[0].strip()
    assert sampler.returncode == 3
    assert int(_fields(line)["mains_offline_samples"]) >= 1


def test_clock_sampler_battery_rule_matches_the_shell(tmp_path):
    sysfs = tmp_path / "sys"
    bat = sysfs / "class/power_supply/BAT1"
    bat.mkdir(parents=True)
    (bat / "type").write_text("Battery\n")
    (bat / "status").write_text("Discharging\n")
    assert cpufreq_sampler.on_battery(str(sysfs))
    mains = sysfs / "class/power_supply/ADP1"
    mains.mkdir()
    (mains / "type").write_text("Mains\n")
    (mains / "online").write_text("1\n")
    assert not cpufreq_sampler.on_battery(str(sysfs))


# lib/openloop_rates.py

def _scan_cell(path, completions_s, extra=()):
    lines = []
    for i, t in enumerate(completions_s):
        tags = {"tier": "28", "status": "200", "phase": "scan", "vus": "64"}
        lines.append(json.dumps({"metric": "http_req_duration", "type": "Point",
                                 "data": {"time": _ts(t * 1000), "value": 5.0, "tags": tags}}))
    lines.extend(extra)
    with gzip.open(path, "wt") as f:
        f.write("\n".join(lines) + "\n")


def test_openloop_plateau_is_the_top_levels_mean_within_rep_throughput(tmp_path):
    _scan_cell(tmp_path / "scan_28_vus64_rep1.json.gz", [i * 0.01 for i in range(101)])   # 100 req/s
    _scan_cell(tmp_path / "scan_28_vus64_rep2.json.gz", [i * 0.02 for i in range(101)])   # 50 req/s
    _scan_cell(tmp_path / "scan_28_vus32_rep1.json.gz", [i * 0.001 for i in range(101)])  # lower level, ignored
    assert openloop_rates.plateau(str(tmp_path), "28") == (64, pytest.approx(75.0))


def test_openloop_plateau_ignores_errors_and_other_phases(tmp_path):
    noise = [json.dumps({"metric": "http_req_duration", "type": "Point",
                         "data": {"time": _ts(50_000), "value": 1.0,
                                  "tags": {"tier": "28", "status": status, "phase": phase}}})
             for status, phase in (("500", "scan"), ("200", "warmup"))]
    _scan_cell(tmp_path / "scan_28_vus64_rep1.json.gz", [i * 0.01 for i in range(101)], extra=noise)
    assert openloop_rates.plateau(str(tmp_path), "28") == (64, pytest.approx(100.0))
    assert openloop_rates.plateau(str(tmp_path), "5") is None
