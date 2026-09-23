"""
Thermal-throttling diagnostic: overlays rolling P50 latency against active
VUs, package temp, and core frequency, so a throttle signature (temp at the
ceiling, frequency dropping, latency climbing) can be read against the load
rather than inferred from temp alone.

Handles warmup_*, baseline_* and scan_* result files (.json or .json.gz)
identically, so throttling at real cell durations is comparable with
throttling in a longer probe. The active-VU line needs the vus metric, which
the harness filters out of finalized files; a raw or probe file keeps it.

--thermal-log takes a `sensors`-polling log (package temp only).
--turbostat-log takes a `turbostat` log (temp + Bzy_MHz frequency, direct
evidence of throttling rather than a temp proxy). If both are given,
turbostat's temp reading wins.

Log format for both: timestamped blocks from a polling loop --

    === 2026-09-15T12:34:56.789Z ===
    <sensors or turbostat output for that tick>

One log covers a whole suite run, so each file's temp/freq points are clipped
to that file's own time window before plotting (see _clip_to_window).

Usage:
    python3 plot_warmup_curve.py [--results-dir ../results] [--output-dir .] \
        [--window 100] [--thermal-log thermal.log] [--turbostat-log turbostat.log]
"""

import argparse
import glob
import gzip
import itertools
import json
import os
import re
import sys

import matplotlib.pyplot as plt
import pandas as pd

COLORS = ["#2b5c8f", "#c0392b", "#27ae60", "#8e44ad", "#e67e22", "#16a085",
          "#d35400", "#2980b9", "#7f8c8d", "#c0392b"]

TS_RE = re.compile(r"^===\s*(\S+)\s*===\s*$")
# "Package id 0:  +65.0C" -- coretemp's package-level reading on Intel hosts.
SENSORS_TEMP_RE = re.compile(r"Package id 0:\s*\+?(-?[\d.]+)")


def _intern_tag(v):
    return sys.intern(v) if type(v) is str else v


def load_file(fp):
    """tier -> {time, value} for http_req_duration, plus the vus series.
    No phase filter -- each results file holds a single phase by
    construction, so warmup/baseline/scan share one loader."""
    by_tier = {}
    vus_time, vus_value = [], []
    opener = gzip.open if fp.endswith(".gz") else open
    with opener(fp, "rt") as f:
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
            metric = obj.get("metric")
            data = obj.get("data", {}) or {}
            if metric == "vus":
                vus_time.append(data.get("time"))
                vus_value.append(data.get("value"))
                continue
            if metric != "http_req_duration":
                continue
            tags = data.get("tags", {}) or {}
            tier = _intern_tag(tags.get("tier"))
            if tier is None:
                continue
            if tier not in by_tier:
                by_tier[tier] = {"time": [], "value": []}
            by_tier[tier]["time"].append(data.get("time"))
            by_tier[tier]["value"].append(data.get("value"))
    return by_tier, vus_time, vus_value


def load_thermal_log(fp):
    """(time_strs, temp_c) from a `sensors`-polling log."""
    times, temps = [], []
    current_ts = None
    with open(fp) as f:
        for line in f:
            m = TS_RE.match(line)
            if m:
                current_ts = m.group(1)
                continue
            m = SENSORS_TEMP_RE.search(line)
            if m and current_ts is not None:
                times.append(current_ts)
                temps.append(float(m.group(1)))
                current_ts = None  # one reading per timestamped block
    return times, temps


def load_turbostat_log(fp):
    """(time_strs, temp_c, freq_mhz) from a `turbostat --interval 1
    --num_iterations 1` polling log. Column positions come from each
    block's own header row (shifts across turbostat versions), and the
    first data row after the header is the package summary."""
    times, temps, freqs = [], [], []
    current_ts = None
    header_idx = None
    for raw in open(fp):
        line = raw.rstrip("\n")
        m = TS_RE.match(line)
        if m:
            current_ts = m.group(1)
            header_idx = None
            continue
        parts = line.split()
        if not parts:
            continue
        if header_idx is None and "PkgTmp" in parts:
            header_idx = {name: i for i, name in enumerate(parts)}
            continue
        if header_idx is not None and current_ts is not None:
            temp_i = header_idx.get("PkgTmp")
            freq_i = header_idx.get("Bzy_MHz", header_idx.get("Avg_MHz"))
            try:
                temp_v = float(parts[temp_i]) if temp_i is not None else None
                freq_v = float(parts[freq_i]) if freq_i is not None else None
            except (ValueError, IndexError):
                temp_v = freq_v = None
            if temp_v is not None or freq_v is not None:
                times.append(current_ts)
                temps.append(temp_v)
                freqs.append(freq_v)
            current_ts = None   # this block's summary row consumed
            header_idx = None   # wait for the next block's own header
    return times, temps, freqs


def _elapsed_seconds(time_strs, t0):
    t = pd.to_datetime(time_strs, format="ISO8601", utc=True)
    return (t - t0).total_seconds()


def _drop_none(times, values):
    pairs = [(t, v) for t, v in zip(times, values) if v is not None]
    if not pairs:
        return [], []
    t, v = zip(*pairs)
    return list(t), list(v)


def _clip_to_window(times, values, window_start, window_end):
    """Restricts a continuously-collected thermal/turbostat log to one
    file's own time span. The temp/freq axes twin the latency axis, so an
    unclipped multi-hour log stretches the shared x-axis and collapses a
    short cell's P50 line to a sliver."""
    if not times:
        return [], []
    t = pd.to_datetime(times, format="ISO8601", utc=True)
    mask = (t >= window_start) & (t <= window_end)
    if not mask.any():
        return [], []
    kept_times = [ts for ts, keep in zip(times, mask) if keep]
    kept_values = [v for v, keep in zip(values, mask) if keep]
    return kept_times, kept_values


def plot_file(fp, output_dir, window, thermal_log=None, turbostat_log=None):
    name = os.path.basename(fp)
    by_tier, vus_time, vus_value = load_file(fp)

    all_times = [t for tier in by_tier.values() for t in tier["time"]] + vus_time
    if not all_times:
        print(f"[!] No http_req_duration/vus data in {name}, skipping.")
        return
    t_all = pd.to_datetime(all_times, format="ISO8601", utc=True)
    t0 = t_all.min()
    t_max = t_all.max()
    duration_s = max((t_max - t0).total_seconds(), 0.001)
    # 10% of the file's own duration, floor 5s -- enough context on each
    # side without bleeding into an unrelated cell's temp/freq readings.
    buffer_s = max(5.0, 0.1 * duration_s)
    window_start = t0 - pd.Timedelta(seconds=buffer_s)
    window_end = t_max + pd.Timedelta(seconds=buffer_s)

    fig, ax = plt.subplots(figsize=(16, 6))
    tiers = sorted(by_tier.keys())
    for tier, color in zip(tiers, itertools.cycle(COLORS)):
        values = by_tier[tier]["value"]
        if len(values) < window:
            print(f"[!] {name}: tier '{tier}' has only {len(values)} points (<{window}), plotting raw instead of rolling.")
            elapsed = _elapsed_seconds(by_tier[tier]["time"], t0)
            ax.plot(elapsed, values, linewidth=0.8, color=color, label=f"{tier} (raw, n={len(values)})")
            continue
        elapsed = _elapsed_seconds(by_tier[tier]["time"], t0)
        roll = pd.Series(values, dtype="float32").rolling(window, min_periods=window).median()
        ax.plot(elapsed, roll.values, linewidth=0.8, color=color, label=f"{tier} P50")
    ax.set_xlabel("elapsed time (s)")
    ax.set_ylabel("P50 (ms)")
    ax.legend(loc="upper left", fontsize=8)

    if vus_time:
        ax2 = ax.twinx()
        elapsed_vus = _elapsed_seconds(vus_time, t0)
        ax2.step(elapsed_vus, vus_value, where="post", color="black", alpha=0.4, linewidth=1.0, label="vus")
        ax2.set_ylabel("active VUs")
        ax2.legend(loc="upper right", fontsize=8)

    # turbostat's temp supersedes sensors' when both logs are given, so the
    # plot never carries two competing temp lines.
    temp_times = temp_values = None
    freq_times = freq_values = None
    if turbostat_log:
        t_times, t_temps, t_freqs = load_turbostat_log(turbostat_log)
        temp_times, temp_values = _drop_none(t_times, t_temps)
        freq_times, freq_values = _drop_none(t_times, t_freqs)
        temp_times, temp_values = _clip_to_window(temp_times, temp_values, window_start, window_end)
        freq_times, freq_values = _clip_to_window(freq_times, freq_values, window_start, window_end)
        if not temp_times and not freq_times:
            print(f"[!] Turbostat log {turbostat_log} had no readings inside {name}'s own "
                  f"time window (+/-{buffer_s:.0f}s) -- log likely doesn't cover when this file ran.")
    elif thermal_log:
        s_times, s_temps = load_thermal_log(thermal_log)
        s_times, s_temps = _clip_to_window(s_times, s_temps, window_start, window_end)
        temp_times, temp_values = s_times, s_temps
        if not temp_times:
            print(f"[!] Thermal log {thermal_log} had no readings inside {name}'s own "
                  f"time window (+/-{buffer_s:.0f}s) -- log likely doesn't cover when this file ran.")

    if temp_times:
        ax3 = ax.twinx()
        ax3.spines["right"].set_position(("outward", 60))
        elapsed_temp = _elapsed_seconds(temp_times, t0)
        ax3.plot(elapsed_temp, temp_values, color="#d62728", linewidth=1.2,
                  linestyle="--", label="pkg temp (C)")
        ax3.set_ylabel("package temp (C)", color="#d62728")
        ax3.tick_params(axis="y", colors="#d62728")
        ax3.legend(loc="lower right", fontsize=8)

    if freq_times:
        ax4 = ax.twinx()
        ax4.spines["right"].set_position(("outward", 120))
        elapsed_freq = _elapsed_seconds(freq_times, t0)
        ax4.plot(elapsed_freq, freq_values, color="#1a1a8f", linewidth=1.0,
                  linestyle=":", label="core freq (MHz)")
        ax4.set_ylabel("Bzy_MHz", color="#1a1a8f")
        ax4.tick_params(axis="y", colors="#1a1a8f")
        ax4.legend(loc="lower left", fontsize=8)

    ax.set_title(f"Rolling P50 (window={window}) vs. VUs / temp / freq — {name}")
    fig.tight_layout()
    out_path = os.path.join(output_dir, f"overlay_{re.sub(r'[.]json(?:[.]gz)?$', '', name)}.png")
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"[+] {out_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default=os.path.join(os.path.dirname(__file__), "..", "results"))
    parser.add_argument("--output-dir", default=".")
    parser.add_argument("--window", type=int, default=100)
    parser.add_argument("--thermal-log", default=None,
                         help="sensors-polling thermal log (package temp only); ignored if --turbostat-log is also given.")
    parser.add_argument("--turbostat-log", default=None,
                         help="turbostat-polling log (package temp AND core frequency).")
    args = parser.parse_args()

    files = []
    for prefix in ("warmup_", "baseline_", "scan_"):
        for suffix in (".json", ".json.gz"):
            files.extend(glob.glob(os.path.join(args.results_dir, f"{prefix}*{suffix}")))
    files = sorted(set(files))
    if not files:
        print(f"[!] No warmup_*/baseline_*/scan_* result files found in {args.results_dir}")
        return
    os.makedirs(args.output_dir, exist_ok=True)
    for fp in files:
        plot_file(fp, args.output_dir, args.window,
                  thermal_log=args.thermal_log, turbostat_log=args.turbostat_log)


if __name__ == "__main__":
    main()