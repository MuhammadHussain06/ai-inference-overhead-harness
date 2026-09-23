"""Warm-up convergence table shared by analyze-results.py and analyze-ablation.py.

Each warm-up file is judged by load-testing/lib/warmup_gate.py itself, at the
parameters the run recorded in its metadata, so the table reports the verdict the
live gate acted on. Every expected target gets a row, including one that never
reached three windows or never returned HTTP 200: a target that did not converge
is the finding, not a row to drop.
"""

import importlib.util
import os

import numpy as np

GATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "load-testing", "lib", "warmup_gate.py")


def _load_gate():
    spec = importlib.util.spec_from_file_location("warmup_gate", GATE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = _load_gate()


def gate_params(config=None):
    """The criterion from a run's recorded warmup_gate block, or the gate's
    defaults for a run that predates recording it."""
    config = config or {}
    return {
        "base_window": int(config.get("base_window", gate.BASE_WINDOW)),
        "min_span_s": float(config.get("min_window_span_s", gate.MIN_WINDOW_SPAN_S)),
        "tol_pct": float(config.get("tail_tolerance_pct", gate.TAIL_TOLERANCE_PCT)),
        "floor_ms": float(config.get("tail_abs_floor_ms", gate.TAIL_ABS_FLOOR_MS)),
    }


def converged_column(params):
    return f"Converged (tail <{params['tol_pct']:g}% or <{params['floor_ms']:g}ms)"


def _num(v, digits):
    return round(float(v), digits) if v is not None and np.isfinite(v) else np.nan


def file_rows(path, expect, params, tier_label):
    """One row per target in a warm-up file (expected targets first), plus whether
    the file was truncated."""
    verdicts, truncated = gate.evaluate_file(path, expect=expect, **params)
    rows = []
    for tier, v in verdicts.items():
        status = v["status"] + (" (file truncated)" if truncated else "")
        rows.append({
            "Tier": tier_label(tier),
            "N Requests": v["n"],
            "Failed Requests": v["n_failed"],
            "Window (requests)": v["window"] if v["window"] is not None else np.nan,
            "Window span (s)": _num(v["window_span_s"], 2),
            "First-window P50 (ms)": _num(v["first_p50"], 3),
            "Prev-window P50 (ms)": _num(v["prev_p50"], 3),
            "Last-window P50 (ms)": _num(v["last_p50"], 3),
            "Total drift (%)": _num(v["total_drift_pct"], 1),
            "Tail drift (%)": _num(v["tail_drift_pct"], 1),
            converged_column(params): "YES" if v["converged"] else "no",
            "Status": status,
        })
    return rows, truncated


def caption(params, scope):
    return (f"{scope} warm-up convergence, judged by the live gate's own criterion. A window is "
            f"at least {params['base_window']} HTTP 200 requests spanning at least "
            f"{params['min_span_s']:g} s. 'Tail drift' compares the last window's median with the "
            f"window before it and is the convergence test: under {params['tol_pct']:g}% or an "
            f"absolute gap under {params['floor_ms']:g} ms, whichever is looser for the target's "
            f"latency scale. 'Total drift' is the change from the first window, large by design, "
            f"and shows how much work warm-up did. A target with fewer than three windows or no "
            f"successful response is listed with that status rather than omitted.")


def report(table, params, what, where_cols):
    """Prints the targets that had not converged; returns how many."""
    if table is None or table.empty:
        return 0
    failed = table[table[converged_column(params)] != "YES"]
    if not failed.empty:
        print(f"[!] {len(failed)}/{len(table)} {what} had not converged when warm-up ended; "
              f"the measurement that followed may not reflect steady state:")
        for _, r in failed.iterrows():
            where = " ".join(f"{c}={r[c]}" for c in where_cols)
            print(f"    {where} tier={r['Tier']}: {r['Status']}")
    return len(failed)
