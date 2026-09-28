"""Guards the scan outlier and connection-placement analysis (lib/scan_outliers.py and
analyze-results.py's tables 4f and 4g)."""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ANALYSIS_DIR = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("analyze_results", ANALYSIS_DIR / "analyze-results.py")
results = importlib.util.module_from_spec(spec)
sys.modules["analyze_results"] = results
spec.loader.exec_module(results)
so = sys.modules["scan_outliers"]

T0 = pd.Timestamp("2026-01-01T00:00:00Z")
STALL, DISPATCH = "python_compute_stall_time_ms", "python_thread_dispatch_time_ms"


def _cell(tier, vus, rep, latency, stall=0.0, dispatch=0.1, n=50, slow_start=1.0):
    source = f"scan_{tier}_vus{vus}_rep{rep}.json.gz"
    base = dict(status="200", phase="scan", tier=tier, vus=float(vus), rep=str(rep), source_file=source)
    rows = []
    for i in range(n):
        value = latency * (slow_start if i < n // 10 else 1.0)
        ts = T0 + pd.Timedelta(milliseconds=10 * i)
        rows.append({**base, "metric": "http_req_duration", "value": value, "time": ts})
        rows.append({**base, "metric": STALL, "value": stall, "time": ts})
        rows.append({**base, "metric": DISPATCH, "value": dispatch, "time": ts})
    return rows


def _scan(outlier_rep=4, outlier_scale=1.4, outlier_stall=0.8):
    rows = []
    for rep in range(1, 8):
        scale, stall = (outlier_scale, outlier_stall) if rep == outlier_rep else (1 + 0.01 * rep, 0.001)
        rows += _cell("10", 2, rep, 2.0 * scale, stall=stall)
        rows += _cell("10", 8, rep, 5.0 * (1 + 0.01 * rep), stall=0.3)
    return pd.DataFrame(rows)


def test_cell_features_measure_a_slow_start_separately_from_a_shifted_cell():
    df = pd.DataFrame(_cell("5", 2, 1, 1.0, slow_start=3.0) + _cell("5", 2, 2, 2.0))
    cells = so.cell_features(df).set_index("rep")
    assert cells.loc["1", "first_tenth_ratio"] == pytest.approx(3.0)
    assert cells.loc["2", "first_tenth_ratio"] == pytest.approx(1.0)
    assert cells.loc["2", "median"] == pytest.approx(2.0)


def test_flag_outliers_flags_only_the_rep_far_above_its_design_cell():
    cells = so.flag_outliers(so.cell_features(_scan()))
    flagged = cells[cells["flagged"]]
    assert flagged[["vus", "rep"]].values.tolist() == [[2, "4"]]
    assert flagged["deviation_pct"].iloc[0] == pytest.approx(100 * (1.4 / 1.05 - 1), rel=1e-3)
    assert flagged["stall_ms_others"].iloc[0] == pytest.approx(0.001)


def test_small_spread_is_not_flagged_even_with_a_large_z():
    cells = so.flag_outliers(so.cell_features(_scan(outlier_scale=1.045, outlier_stall=0.001)))
    assert not cells["flagged"].any()


def _log(tmp_path, lines):
    (tmp_path / "connection_placement_log.txt").write_text("\n".join(lines) + "\n")


def test_placement_log_takes_the_longest_held_connected_state(tmp_path):
    _log(tmp_path, [
        "placement cell=scan_10_vus2_rep4 ts=2026-01-01T00:00:00.000Z established=0 workers=9:0,10:0,11:0",
        "placement cell=scan_10_vus2_rep4 ts=2026-01-01T00:00:01.000Z established=2 workers=9:2,10:0,11:0",
        "placement cell=scan_10_vus2_rep4 ts=2026-01-01T00:00:02.000Z established=2 workers=9:1,10:1,11:0",
        "placement_end cell=scan_10_vus2_rep4 ts=2026-01-01T00:00:02.200Z",
        "placement cell=scan_10_vus2_rep5 ts=2026-01-01T00:00:03.000Z established=0 workers=9:0,10:0,11:0",
        "placement_end cell=scan_10_vus2_rep5 ts=2026-01-01T00:00:03.100Z",
        "placement_unavailable cell=scan_10_vus2_rep6 ts=2026-01-01T00:00:04.000Z reason=container_pid_unresolved",
    ])
    p = so.parse_placement_log(str(tmp_path)).set_index("cell")
    assert p.loc["scan_10_vus2_rep4", "placement"] == "2-0-0"
    assert p.loc["scan_10_vus2_rep4", "crowding"] == 2.0
    assert p.loc["scan_10_vus2_rep4", "crowding_above_even"] == 1.0
    assert p.loc["scan_10_vus2_rep5", "placement"] == "unrecorded"
    assert p.loc["scan_10_vus2_rep6", "placement"] == "unavailable (container_pid_unresolved)"


@pytest.mark.parametrize("counts,above", [((1, 1, 0), 0.0), ((2, 0, 0), 1.0), ((2, 1, 1), 0.0), ((2, 2, 0), 0.5),
                                          ((3, 1, 0), 1.0), ((4, 0, 0), 2.5), ((3, 3, 2), 0.0), ((5, 3, 0), 1.5)])
def test_crowding_above_even_ranks_every_shared_worker_above_the_even_split(counts, above):
    assert so.crowding(counts) - so.even_crowding(sum(counts), len(counts)) == pytest.approx(above)


def test_placement_log_absent_is_none(tmp_path):
    assert so.parse_placement_log(str(tmp_path)) is None


def test_placement_table_separates_uneven_from_even_cells():
    rng = np.random.default_rng(1)
    rows = []
    for i in range(12):
        uneven = i < 4
        rows.append({"cell": f"c{i}", "tier": "10", "vus": 2, "rep": str(i),
                     "deviation_pct": (40 if uneven else 0) + rng.normal(0, 2),
                     "stall_ms": 0.8 if uneven else 0.001, "dispatch_ms": 0.2,
                     "placement": "2-0-0" if uneven else "1-1-0", "crowding_above_even": 1.0 if uneven else 0.0})
    table = so.placement_table(pd.DataFrame(rows)).set_index("Crowding above even split")
    assert table.loc[1, "Cells"] == 4 and table.loc[0, "Cells"] == 8
    assert table.loc[1, "Median extra compute stall (ms)"] == pytest.approx(0.8 - 0.001, abs=1e-3)
    assert table.loc[1, "Mann-Whitney p vs even"] < 0.01
    assert table.loc[1, "Rank-biserial r vs even"] == pytest.approx(1.0)
    assert np.isnan(table.loc[0, "Mann-Whitney p vs even"])


def test_analysis_writes_the_outlier_and_placement_outputs(tmp_path):
    lines = []
    for rep in range(1, 8):
        counts = "9:2,10:0,11:0" if rep == 4 else "9:1,10:1,11:0"
        cell = f"scan_10_vus2_rep{rep}"
        lines += [f"placement cell={cell} ts=2026-01-01T00:00:0{rep}.000Z established=2 workers={counts}",
                  f"placement_end cell={cell} ts=2026-01-01T00:00:0{rep}.500Z"]
    _log(tmp_path, lines)
    results.analyze_scan_outliers(str(tmp_path), str(tmp_path), {}, _scan())
    t4f = pd.read_csv(tmp_path / "tables" / "table4f_scan_outlier_cells.csv")
    assert t4f["Rep"].tolist() == [4] and t4f["Placement"].tolist() == ["2-0-0"]
    t4g = pd.read_csv(tmp_path / "tables" / "table4g_scan_connection_placement.csv")
    assert t4g["Example placement"].tolist() == ["1-1-0", "2-0-0"]
    assert (tmp_path / "figures" / "figure9_scan_connection_placement.png").exists()


def test_analysis_without_a_placement_log_still_writes_the_outlier_table(tmp_path, capsys):
    results.analyze_scan_outliers(str(tmp_path), str(tmp_path), {}, _scan())
    assert (tmp_path / "tables" / "table4f_scan_outlier_cells.csv").exists()
    assert not (tmp_path / "tables" / "table4g_scan_connection_placement.csv").exists()
    assert "No connection_placement_log.txt" in capsys.readouterr().out
