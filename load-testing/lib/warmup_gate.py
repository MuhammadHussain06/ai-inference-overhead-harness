#!/usr/bin/env python3
"""Warm-up convergence criterion, shared by converge_warmup() in run-suite.sh and
run-ablation.sh, the warm-up probes, and table0 in both analysis scripts, so the
table reports the verdict the live gate acted on rather than a re-implementation
of it.

A target has converged when the median of its last window of HTTP 200 latencies
is within TAIL_TOLERANCE_PCT, or within TAIL_ABS_FLOOR_MS, of the window before
it. A window is at least BASE_WINDOW requests and spans at least
MIN_WINDOW_SPAN_S of the target's own traffic: at the zero-work targets'
throughput a fixed request count covers tens of milliseconds, shorter than the
JVM's GC cycle and scheduler timescales, so two such windows sample different
transient states and read that as drift.

    warmup_gate.py FILE --expect "mock calibration 5 ..." [--label L]

prints "true" if every expected target converged, "false" otherwise, with one
line per target on stderr.
"""

import argparse
import collections
import gzip
import json
import math
import statistics
import sys
from datetime import datetime, timezone

BASE_WINDOW = 500
MIN_WINDOW_SPAN_S = 3.0
TAIL_TOLERANCE_PCT = 5.0
TAIL_ABS_FLOOR_MS = 0.25

# Per-target retention while streaming. The tail holds two windows at up to
# 20,000 req/s, several times the fastest target's rate; the head only feeds
# the descriptive first-window median.
TAIL_RETAIN = 120_000
HEAD_RETAIN = 60_000

# Skips the other metrics' lines without parsing them.
_METRIC_MARK = '"http_req_duration"'


def _split_offset(t):
    if t.endswith("Z"):
        return t[:-1], 0
    if len(t) > 6 and t[-6] in "+-" and t[-3] == ":":
        sign = 1 if t[-6] == "+" else -1
        return t[:-6], sign * (int(t[-5:-3]) * 3600 + int(t[-2:]) * 60)
    return t, 0


def ts_key(t):
    """Sort key for a k6 RFC3339 timestamp. Go trims trailing zeros from the
    fraction (and the '.' for a whole second), so plain string order would put
    '...07Z' after '...07.5Z'."""
    body, _ = _split_offset(t)
    whole, _, frac = body.partition(".")
    return whole, frac.ljust(9, "0")


def ts_seconds(t):
    """Epoch seconds for a k6 RFC3339 timestamp, without datetime's truncation of
    the fraction to microseconds."""
    body, offset = _split_offset(t)
    whole, _, frac = body.partition(".")
    base = datetime.strptime(whole, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    return base + (float("0." + frac) if frac else 0.0) - offset


class TierPoints:
    """One target's HTTP 200 latencies as (timestamp, ms) in file order: every
    point up to head_retain, and the most recent tail_retain."""

    __slots__ = ("n_ok", "n_failed", "head", "tail", "_head_retain")

    def __init__(self, head_retain=HEAD_RETAIN, tail_retain=TAIL_RETAIN):
        self.n_ok = 0
        self.n_failed = 0
        self.head = []
        self.tail = collections.deque(maxlen=tail_retain)
        self._head_retain = head_retain

    def add(self, t, value):
        self.n_ok += 1
        if len(self.head) < self._head_retain:
            self.head.append((t, value))
        self.tail.append((t, value))


def read_points(path, head_retain=HEAD_RETAIN, tail_retain=TAIL_RETAIN):
    """Streams a k6 JSON-lines file (plain or gzip) into {tier: TierPoints}.
    Returns (tiers, truncated); a gzip stream that ends early keeps what was
    read before it and sets truncated."""
    tiers = {}
    truncated = False
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        try:
            for line in f:
                if _METRIC_MARK not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "Point" or obj.get("metric") != "http_req_duration":
                    continue
                data = obj.get("data") or {}
                tags = data.get("tags") or {}
                tier, t, value = tags.get("tier"), data.get("time"), data.get("value")
                if tier is None or t is None or value is None:
                    continue
                points = tiers.get(tier)
                if points is None:
                    points = tiers[tier] = TierPoints(head_retain, tail_retain)
                if tags.get("status") == "200":
                    points.add(t, float(value))
                else:
                    points.n_failed += 1
        except (EOFError, OSError):
            truncated = True
    return tiers, truncated


def effective_window(tail, base_window=BASE_WINDOW, min_span_s=MIN_WINDOW_SPAN_S):
    """Requests per window for a time-sorted [(timestamp, ms)] tail: the smallest
    multiple of base_window whose most recent requests span at least min_span_s.
    Exceeds len(tail) when the tail is too short to span it."""
    window = base_window
    if min_span_s <= 0 or len(tail) < 2:
        return window
    t_end = ts_seconds(tail[-1][0])
    while window < len(tail) and t_end - ts_seconds(tail[-window][0]) < min_span_s:
        window += base_window
    return window


def evaluate(points, base_window=BASE_WINDOW, min_span_s=MIN_WINDOW_SPAN_S,
             tol_pct=TAIL_TOLERANCE_PCT, floor_ms=TAIL_ABS_FLOOR_MS):
    """Verdict for one target's TierPoints (None: no request at all). status is
    "converged", "drifting", "no HTTP 200 responses", "fewer than three windows"
    or "no requests"; only "converged" passes the gate."""
    result = {
        "n": 0, "n_failed": 0, "window": None, "window_span_s": None,
        "first_p50": None, "prev_p50": None, "last_p50": None,
        "total_drift_pct": None, "tail_drift_pct": None,
        "converged": False, "status": "no requests",
    }
    if points is None:
        return result
    result["n"], result["n_failed"] = points.n_ok, points.n_failed
    if points.n_ok == 0:
        result["status"] = "no HTTP 200 responses"
        return result

    tail = sorted(points.tail, key=lambda p: ts_key(p[0]))
    window = effective_window(tail, base_window, min_span_s)
    # Two windows always fit in the retained tail below 20,000 req/s; above it the
    # window is held to what was retained rather than read across a gap.
    if 2 * window > len(tail) and points.n_ok > len(tail):
        window = base_window * max(1, len(tail) // (2 * base_window))
    result["window"] = window
    if points.n_ok < 3 * window:
        result["status"] = "fewer than three windows"
        return result

    head = tail if points.n_ok <= len(tail) else sorted(points.head, key=lambda p: ts_key(p[0]))
    first = statistics.median(v for _, v in head[:window])
    prev = statistics.median(v for _, v in tail[-2 * window:-window])
    last = statistics.median(v for _, v in tail[-window:])
    tail_drift = 100 * (last - prev) / prev if prev else math.inf
    converged = abs(last - prev) < floor_ms or abs(tail_drift) < tol_pct
    result.update({
        "window_span_s": ts_seconds(tail[-1][0]) - ts_seconds(tail[-window][0]),
        "first_p50": first, "prev_p50": prev, "last_p50": last,
        "total_drift_pct": 100 * (last - first) / first if first else math.inf,
        "tail_drift_pct": tail_drift,
        "converged": converged,
        "status": "converged" if converged else "drifting",
    })
    return result


def evaluate_file(path, expect=None, **params):
    """{tier: verdict} for every target in the file plus every expected one, and
    whether the file was truncated."""
    tiers, truncated = read_points(path)
    names = list(dict.fromkeys(list(expect or []) + list(tiers)))
    return {tier: evaluate(tiers.get(tier), **params) for tier in names}, truncated


def describe(tier, v):
    if v["prev_p50"] is None:
        detail = f"n={v['n']} failed={v['n_failed']}" + (f" window={v['window']}" if v["window"] else "")
    else:
        detail = (f"n={v['n']} window={v['window']} ({v['window_span_s']:.1f}s) "
                  f"first={v['first_p50']:.3f}ms prev={v['prev_p50']:.3f}ms last={v['last_p50']:.3f}ms "
                  f"tail_drift={v['tail_drift_pct']:+.1f}% total_drift={v['total_drift_pct']:+.1f}%")
    return f"tier={tier} {detail} -> {v['status']}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("path")
    parser.add_argument("--expect", required=True, help="space-separated tier tags that must converge")
    parser.add_argument("--label", default="")
    parser.add_argument("--window", type=int, default=BASE_WINDOW)
    parser.add_argument("--min-span-s", type=float, default=MIN_WINDOW_SPAN_S)
    parser.add_argument("--tol", type=float, default=TAIL_TOLERANCE_PCT)
    parser.add_argument("--floor", type=float, default=TAIL_ABS_FLOOR_MS)
    args = parser.parse_args(argv)

    expect = args.expect.split()
    verdicts, truncated = evaluate_file(
        args.path, expect=expect, base_window=args.window, min_span_s=args.min_span_s,
        tol_pct=args.tol, floor_ms=args.floor,
    )
    prefix = f"  [warmup-gate] {args.label}: " if args.label else "  [warmup-gate] "
    for tier in expect:
        print(prefix + describe(tier, verdicts[tier]), file=sys.stderr)
    if truncated:
        print(prefix + "input ended early; judged on what was read", file=sys.stderr)
    print("true" if expect and all(verdicts[t]["converged"] for t in expect) else "false")


if __name__ == "__main__":
    main()
