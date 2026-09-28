"""Guards run-directory discovery, the host-variance environment gate and statistics,
and both host-variance scripts end to end on synthetic runs."""

import gzip
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ANALYSIS_DIR = Path(__file__).resolve().parents[1]
LOAD_TESTING_DIR = ANALYSIS_DIR.parent / "load-testing"


def _load(module_name, filename):
    spec = importlib.util.spec_from_file_location(module_name, ANALYSIS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


suite_hv = _load("analyze_host_variance", "analyze-host-variance.py")
ablation_hv = _load("analyze_ablation_host_variance", "analyze-ablation-host-variance.py")
results = sys.modules["analyze_results"]
run_dirs = sys.modules["run_dirs"]
hv = sys.modules["hostvariance"]

T0 = pd.Timestamp("2026-01-01T00:00:00Z")


def _point(metric, value, tags, ts):
    return json.dumps({"type": "Point", "metric": metric,
                       "data": {"time": ts.strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "value": value, "tags": tags}})


def _write(path, lines):
    with gzip.open(path, "wt") as f:
        f.write("\n".join(lines) + "\n")


def _meta(host, kind="suite", python="0-1,4-5,8-9", java="2-3,6-7", k6="10-11,14-15",
          isolation="python=0,4,8 java=2,6 k6=10,14", **overrides):
    cores = {"python_service_cpuset": python, "python_service_cores": len(hv.expand_cpuset(python)),
             "transaction_service_cpuset": java, "transaction_service_cores": len(hv.expand_cpuset(java)),
             "k6_cpuset": k6, "k6_cores": len(hv.expand_cpuset(k6)), "physical_core_isolation": isolation,
             "python_service_cpus_quota": "6", "transaction_service_cpus_quota": "4", "k6_cpus_quota": "4"}
    meta = {"run_id": f"{kind}_{host}_20260101T000000Z", "hostname": host, "machine_id_hash": f"id-{host}",
            "timestamp_utc": "2026-01-01T00:00:00Z", "git_commit": "a" * 40, "git_dirty": "false",
            "measurement_fingerprint": "f" * 64, "wsl2_detected": "false", "k6_image": "grafana/k6:0.54.0",
            "k6_image_digest": "grafana/k6@sha256:" + "1" * 64, "cpu_model": f"CPU of {host}",
            "cpu_count": "32", "cpu_governor_at_start": "performance", "total_mem_kb": "16000000",
            "jvm_pinned_options": "-Xms1536m -Xmx1536m -XX:+UseG1GC",
            "host_provenance": {"isolcpus_live": "none", "isolcpus_cmdline": "none", "power_source": "ac",
                                "irqbalance": "inactive", "virtualization": "none"},
            "power_state": {"turbo_required": "off", "turbo": "off", "power_source": "ac",
                            "governor": "performance", "energy_preference": "performance",
                            "power_profile": "performance", "thermald": "stopped",
                            "power_limits": "msr_pl1=100W,msr_pl2=250W"},
            "cores_used_by_suite": cores}
    if kind == "suite":
        meta["suite_config"] = {"targets": ["calibration", "28"], "concurrency_levels": [1, 8], "reps_baseline": 3}
    else:
        meta["ablation_config"] = {"target": "28", "vus": 8, "reps": 3,
                                   "control_values": {"thread_limiter": "40", "cpuset": python, "workers": "3"},
                                   "cells": [f"cpuset:{c}:{c}:{len(hv.expand_cpuset(c))}.0:3:40"
                                             for c in ("0-1", python)]}
    for key, value in overrides.items():
        section, _, field = key.partition("__")
        if field:
            meta[section][field] = value
        else:
            meta[key] = value
    return meta


# Synthetic runs

STAGE_SHARES = {"python_thread_dispatch_time_ms": 0.1, "python_dataframe_construction_time_ms": 0.05,
                "python_model_inference_time_ms": 0.75}


def _suite_cell(path, phase, tier, rep, vus, latency_ms, spacing_ms, n=30):
    tags = {"tier": tier, "phase": phase, "rep": str(rep), "status": "200"}
    if vus is not None:
        tags["vus"] = str(vus)
    lines = []
    for i in range(n):
        ts = T0 + pd.Timedelta(milliseconds=spacing_ms * i)
        lines.append(_point("http_req_duration", latency_ms * (1 + 0.02 * (i % 3)), tags, ts))
        python_total = 0.8 * latency_ms
        lines.append(_point("python_total_time_ms", python_total, tags, ts))
        for metric, share in STAGE_SHARES.items():
            lines.append(_point(metric, share * python_total, tags, ts))
    _write(path, lines)


def make_suite_run(root, host, speed=1.0, v28_extra=1.0, **meta_overrides):
    """A run-suite.sh run of calibration and v28 at VUS 1 and 8, three reps. speed scales
    every absolute latency and inter-request gap; v28_extra scales v28 alone."""
    run = Path(root) / f"suite_{host}_20260101T000000Z"
    run.mkdir(parents=True)
    (run / "run_metadata.json").write_text(json.dumps(_meta(host, **meta_overrides)))
    for rep in (1, 2, 3):
        noise = 1 + 0.03 * rep
        for tier, base in (("calibration", 2.0), ("28", 5.0 * v28_extra)):
            lat = base * speed * noise
            _suite_cell(run / f"baseline_{tier}_rep{rep}.json.gz", "baseline", tier, rep, None, lat, 10 * lat)
            for vus in (1, 8):
                load = 1.0 if vus == 1 else 3.0
                _suite_cell(run / f"scan_{tier}_vus{vus}_rep{rep}.json.gz", "scan", tier, rep, vus,
                            lat * load, 10 * lat * load / vus)
    return run


def make_ablation_run(root, host, python="0-1,4-5,8-9", speed=1.0, effect=3.0, **meta_overrides):
    """A run-ablation.sh cpuset arm, control python and a 2-CPU extreme, three reps."""
    run = Path(root) / f"ablation_{host}_20260101T000000Z"
    run.mkdir(parents=True)
    (run / "ablation_run_metadata.json").write_text(
        json.dumps(_meta(host, kind="ablation", python=python, **meta_overrides)))
    for rep in (1, 2, 3):
        for value, factor in ((python, 1.0), ("0-1", effect)):
            tags = {"phase": "ablation", "arm": "cpuset", "arm_value": value, "rep": str(rep), "status": "200"}
            lines = []
            for i in range(20):
                ts = T0 + pd.Timedelta(milliseconds=10 * i)
                dispatch = 0.5 * speed * factor * (1 + 0.02 * rep)
                lines.append(_point("python_thread_dispatch_time_ms", dispatch, tags, ts))
                lines.append(_point("python_total_time_ms", 4 * speed * (1 + 0.02 * rep) + dispatch, tags, ts))
                lines.append(_point("http_req_duration", 6.0, tags, ts))
            _write(run / f"ablation_cpuset_{value}_rep{rep}.json.gz", lines)
    return run


def _main(module, monkeypatch, *argv):
    monkeypatch.setattr(sys, "argv", ["script", *map(str, argv)])
    try:
        module.main()
    except SystemExit as e:
        return e.code or 0
    return 0


def _table(out, name):
    [path] = (Path(out) / "hostvariance" / "tables").glob(f"{name}_*.csv")
    return pd.read_csv(path)


# run_dirs

@pytest.mark.parametrize("name", ["My_Host Name!", "HOST.local", "___", "katana-15"])
def test_host_label_matches_the_harness_sanitizer(name):
    bash = subprocess.run(
        ["bash", "-c", f". '{LOAD_TESTING_DIR / 'lib/run-layout.sh'}'; uname() {{ printf '%s' \"$NAME\"; }}; "
                       "run_host_label"],
        env={**os.environ, "NAME": name}, capture_output=True, text=True, check=True)
    assert run_dirs.host_label(name) == bash.stdout


def test_resolve_finds_run_dirs_of_the_kind_and_skips_archive(tmp_path):
    for name, meta_file in (("suite_a_20260101T000000Z", "run_metadata.json"),
                            ("ablation_a_20260101T000000Z", "ablation_run_metadata.json"),
                            ("archive/suite_a_20250101T000000Z", "run_metadata.json")):
        (tmp_path / name).mkdir(parents=True)
        (tmp_path / name / meta_file).write_text("{}")
    assert [r.name for r in run_dirs.resolve([str(tmp_path)], "suite")] == ["suite_a_20260101T000000Z"]
    assert [r.name for r in run_dirs.resolve([str(tmp_path)], "ablation")] == ["ablation_a_20260101T000000Z"]


def test_resolve_treats_a_flat_pre_v12_results_dir_as_one_run(tmp_path):
    (tmp_path / "baseline_28_rep1.json.gz").write_bytes(b"")
    (tmp_path / "run_metadata.json").write_text(json.dumps(
        {"host_uname": "Linux Old-Host 6.0 x86_64", "timestamp_utc": "2025-05-06T07:08:09Z"}))
    (tmp_path / "ablation_run_metadata.json").write_text(json.dumps({"timestamp_utc": "2025-05-07T00:00:00Z"}))
    [suite] = run_dirs.resolve([str(tmp_path)], "suite")
    [ablation] = run_dirs.resolve([str(tmp_path)], "ablation")
    assert suite.name == "suite_old-host_20250506T070809Z"
    assert ablation.host == "old-host"  # from the suite metadata beside it


def test_resolve_does_not_read_a_runs_scratch_or_log_subdirectories_as_runs(tmp_path):
    run = tmp_path / "suite_a_20260101T000000Z"
    for sub in ("raw", "gc-logs"):
        (run / sub).mkdir(parents=True)
        (run / sub / "scan_28_vus8_rep1.json").write_text("")
    (run / "run_metadata.json").write_text("{}")
    (tmp_path / "raw").mkdir()
    (tmp_path / "raw" / "warmup_scan_rep1.json").write_text("")
    assert [r.path for r in run_dirs.resolve([str(tmp_path)], "suite")] == [str(run)]
    assert [r.path for r in run_dirs.resolve([str(run)], "suite")] == [str(run)]


def test_resolve_rejects_two_directories_with_one_identity(tmp_path):
    for name in ("suite_a_20260101T000000Z", "copy"):
        (tmp_path / name).mkdir()
        (tmp_path / name / "run_metadata.json").write_text(json.dumps({"run_id": "suite_a_20260101T000000Z"}))
    with pytest.raises(ValueError, match="both identify as"):
        run_dirs.resolve([str(tmp_path)], "suite")


def test_prepare_run_outputs_clears_only_its_own_kind(tmp_path):
    for sub in ("tables", "figures"):
        for entry in ("suite_old_20250101T000000Z", "ablation_keep_20250101T000000Z"):
            (tmp_path / sub / entry).mkdir(parents=True)
        (tmp_path / sub / "table1_flat_layout.csv").write_text("")
    (tmp_path / "hostvariance" / "tables").mkdir(parents=True)
    (tmp_path / "hostvariance" / "tables" / "table_hv1_x.csv").write_text("")
    run = run_dirs.Run("suite", str(tmp_path / "suite_new_20260101T000000Z"))
    outs = run_dirs.prepare_run_outputs(str(tmp_path), "suite", [run])
    for sub in ("tables", "figures"):
        assert sorted(os.listdir(tmp_path / sub)) == ["ablation_keep_20250101T000000Z"]
    assert (tmp_path / "hostvariance" / "tables" / "table_hv1_x.csv").exists()
    assert outs[run.name].tables == str(tmp_path / "tables" / run.name)


def test_prepare_hostvariance_outputs_clears_own_prefix_and_suffixes_names(tmp_path):
    tables = tmp_path / "hostvariance" / "tables"
    tables.mkdir(parents=True)
    (tables / "table_hv1_a_b_20250101.csv").write_text("")
    (tables / "table_ablation_hv1_a_b_20250101.csv").write_text("")
    out = run_dirs.prepare_hostvariance_outputs(str(tmp_path), ("table_hv", "figure_hv"), ["a", "b"], "20260101")
    assert os.listdir(tables) == ["table_ablation_hv1_a_b_20250101.csv"]
    assert out.suffix == "_a_b_20260101"
    long = run_dirs.prepare_hostvariance_outputs(str(tmp_path), ("table_hv",), ["x" * 100, "y" * 100], "20260101")
    assert long.suffix == "_2runs_20260101"


# environment gate

class _Run:
    def __init__(self, metadata, kind="suite", path="/nonexistent"):
        self.metadata, self.kind, self.path = metadata, kind, path
        self.host = metadata.get("hostname", "h")
        self.machine = metadata.get("machine_id_hash")


def _gate(*metas):
    runs = [_Run(m) for m in metas]
    table, mismatched, unverified = hv.environment_table(runs, [f"r{i}" for i in range(len(runs))],
                                                         lambda r: r.metadata.get("suite_config"))
    return table.set_index("Field")["Status"].to_dict(), [f for f, _ in mismatched], unverified


def test_gate_compares_core_counts_and_isolation_not_cpu_numbers():
    a = _meta("a")
    b = _meta("b", python="16-21", java="22-25", k6="26-29", isolation="python=16,18,20 java=22,24 k6=26,28")
    status, mismatched, _ = _gate(a, b)
    assert mismatched == []
    assert status["Service CPUs (logical)"] == status["Service cores (physical)"] == "match"
    assert status["CPU model"] == "differs"


def test_gate_flags_a_different_core_count_isolation_level_or_governor():
    a = _meta("a")
    fewer = _meta("b", python="0-3", isolation="python=0,2 java=4,6 k6=8,10")
    unverifiable = _meta("c", isolation="unverifiable (thread_siblings_list not exposed)")
    powersave = _meta("d", cpu_governor_at_start="powersave")
    assert "Service CPUs (logical)" in _gate(a, fewer)[1]
    assert "Physical-core isolation" in _gate(a, unverifiable)[1]
    assert _gate(a, powersave)[1] == ["CPU governor"]


def test_gate_flags_a_different_turbo_setting_and_leaves_older_runs_unverified():
    a, b = _meta("a"), _meta("b", power_state__turbo="on")
    assert _gate(a, b)[1] == ["Turbo"]
    older = _meta("c")
    del older["power_state"]
    status, mismatched, unverified = _gate(a, older)
    assert status["Turbo"] == "unverified" and "Turbo" in unverified and mismatched == []


def test_power_limits_are_gated_only_between_runs_of_one_machine():
    a = _meta("a")
    other_host = _meta("b", power_state__power_limits="msr_pl1=65W,msr_pl2=115W")
    status, mismatched, _ = _gate(a, other_host)
    assert status["CPU power limits"] == "differs between machines" and mismatched == []
    capped = _meta("a", power_state__power_limits="msr_pl1=30W,msr_pl2=35W")
    status, mismatched, _ = _gate(a, capped)
    assert status["CPU power limits"] == "MISMATCH" and mismatched == ["CPU power limits"]


def test_gate_flags_a_different_cpu_quota():
    a = _meta("a")
    b = _meta("b", cores_used_by_suite__python_service_cpus_quota="4.0")
    assert _gate(a, b)[1] == ["Service CPU quotas"]
    c = _meta("c", cores_used_by_suite__python_service_cpus_quota="6.0")
    assert _gate(a, c)[1] == []


def test_gate_reports_a_field_one_run_did_not_record_as_unverified():
    a = _meta("a")
    b = _meta("b")
    del b["cpu_governor_at_start"]
    status, mismatched, unverified = _gate(a, b)
    assert status["CPU governor"] == "unverified"
    assert "CPU governor" in unverified and mismatched == []


@pytest.mark.parametrize("live,expected", [("0-15", "all"), ("0-1", "partial"), ("none", "none")])
def test_isolcpus_coverage_of_the_pinned_cpus(live, expected):
    meta = _meta("a", host_provenance__isolcpus_live=live)
    assert hv.pinned_isolcpus(_Run(meta)) == expected


def test_gate_prefers_the_measurement_fingerprint_over_the_commit():
    a, b = _meta("a"), _meta("b", git_commit="b" * 40)
    status, mismatched, _ = _gate(a, b)
    assert status["Measured code (fingerprint)"] == "match" and mismatched == []
    del b["measurement_fingerprint"]
    assert _gate(a, b)[1] == ["Measured code (git commit)"]


def test_display_abbreviates_long_values_by_their_own_digest():
    assert hv._display("grafana/k6@sha256:" + "ab" * 32) == "ab" * 6
    assert hv._display("x" * 50).startswith("hash:")
    assert hv._display(None) == "unrecorded"


# statistics

def test_ratio_bootstrap_is_reproducible_and_needs_two_reps():
    num, den = {"1": 2.0, "2": 2.2, "3": 2.1}, {"1": 1.0, "2": 1.0, "3": 1.1}
    est, boot = hv.ratio_bootstrap(num, den, ("k",))
    assert est == pytest.approx(6.3 / 3.1)
    assert np.array_equal(boot, hv.ratio_bootstrap(num, den, ("k",))[1])
    assert hv.ratio_bootstrap({"1": 2.0}, {"1": 1.0}, ("k",))[1] is None


@pytest.mark.parametrize("lo,hi,expected", [(-4, 6, "equivalent"), (-9, 9.9, "equivalent"),
                                            (-9.5, 5, "inconclusive"), (12, 30, "different"),
                                            (-30, -9.2, "different"), (-5, 15, "inconclusive"),
                                            (np.nan, 1, "insufficient reps")])
def test_verdict_is_tost_on_the_90_percent_interval(lo, hi, expected):
    """Bounds for a 10% margin on the ratio: 1/1.1 - 1 = -9.09% and +10%."""
    assert hv.verdict(lo, hi, 10) == expected


def test_verdict_does_not_depend_on_which_run_is_the_reference():
    reps = {str(r): 1 + 0.002 * r for r in range(1, 8)}
    ones = {r: 1.0 for r in reps}
    near_margin = {r: 1.1 * v for r, v in reps.items()}
    for a, b in ((reps, near_margin), (near_margin, reps)):
        metric = {"family": "F", "metric": "m", "series": [(a, ones), (b, ones)]}
        summary, _ = hv.compare([metric], ["x", "y"], 10)
        assert summary["Verdict (10% margin)"].iloc[0] == "inconclusive"


def test_compare_finds_equal_ratios_equivalent_and_a_shifted_one_different():
    reps = {str(r): 1 + 0.01 * r for r in range(1, 8)}
    same = {"family": "F", "metric": "same", "series": [
        (reps, {r: 1.0 for r in reps}), ({r: 2 * v for r, v in reps.items()}, {r: 2.0 for r in reps})]}
    shifted = {"family": "F", "metric": "shifted", "series": [
        (reps, {r: 1.0 for r in reps}), ({r: 1.5 * v for r, v in reps.items()}, {r: 1.0 for r in reps})]}
    summary, pairwise = hv.compare([same, shifted], ["a", "b"], 10)
    verdicts = dict(zip(summary["Metric"], summary["Verdict (10% margin)"]))
    assert verdicts == {"same": "equivalent", "shifted": "different"}
    assert pairwise.set_index("Metric").loc["shifted", "Difference (%)"] == pytest.approx(50.0)


def test_kendalls_w_spans_agreement_to_disagreement():
    assert hv.kendalls_w([[1, 2, 3, 4], [10, 20, 30, 40]])[0] == pytest.approx(1.0)
    assert hv.kendalls_w([[1, 2, 3, 4], [4, 3, 2, 1]])[0] == pytest.approx(0.0)
    w, _, df, _ = hv.kendalls_w([[1, 1, 2], [1, 2, 3]])
    assert 0 < w < 1 and df == 2


def test_saturation_level_is_the_first_level_near_the_peak():
    assert hv.saturation_level([1, 2, 4, 8], [10, 50, 96, 100]) == 4
    assert hv.saturation_level([1, 2], [np.nan, np.nan]) is None


def test_same_hostname_on_different_machines_is_not_one_host():
    a, b = _Run({"hostname": "ubuntu", "machine_id_hash": "m1"}), _Run({"hostname": "ubuntu", "machine_id_hash": "m2"})
    assert not hv.shares_machine([a, b])
    b.machine = "m1"
    assert hv.shares_machine([a, b])
    b.machine = None
    assert hv.shares_machine([a, b])


def test_run_labels_disambiguate_a_repeated_host():
    runs = [_Run({"hostname": "a"}), _Run({"hostname": "a"}), _Run({"hostname": "b"})]
    runs[0].timestamp, runs[1].timestamp, runs[2].timestamp = "T1", "T2", "T3"
    runs[0].host = runs[1].host = "a"
    runs[2].host = "b"
    assert hv.run_labels(runs) == ["a-T1", "a-T2", "b"]


# end to end

@pytest.fixture(scope="module")
def two_hosts(tmp_path_factory):
    """Host b is twice as slow as host a, with identical internal ratios."""
    root = tmp_path_factory.mktemp("results")
    make_suite_run(root, "hosta")
    make_suite_run(root, "hostb", speed=2.0, python="16-21", java="22-25", k6="26-29",
                   isolation="python=16,18,20 java=22,24 k6=26,28")
    return root


def test_suite_host_variance_finds_a_uniformly_slower_host_equivalent(two_hosts, tmp_path, monkeypatch):
    assert _main(suite_hv, monkeypatch, "--results-dir", two_hosts, "--output-dir", tmp_path) == 0
    summary = _table(tmp_path, "table_hv1_portable_metrics")
    assert set(summary["Verdict (10% margin)"]) == {"equivalent"}
    context = _table(tmp_path, "table_hv5_host_context").set_index("Quantity")
    lat = context.loc["Baseline mean latency, v28 (ms)"].astype(float)
    assert lat["hostb"] == pytest.approx(2 * lat["hosta"], rel=0.01)
    assert set(_table(tmp_path, "table_hv3_saturation_points")["Same on every run"]) == {"yes"}
    figures = os.listdir(tmp_path / "hostvariance" / "figures")
    assert any(f.startswith("figure_hv1_normalized_throughput_hosta_hostb_") for f in figures)


def test_suite_host_variance_detects_a_tier_that_scales_differently(tmp_path, monkeypatch):
    root = tmp_path / "results"
    make_suite_run(root, "hosta")
    make_suite_run(root, "hostb", v28_extra=1.5)
    assert _main(suite_hv, monkeypatch, root, "--output-dir", tmp_path / "out") == 0
    summary = _table(tmp_path / "out", "table_hv1_portable_metrics").set_index(["Family", "Metric"])
    assert summary.loc[("Baseline latency / calibration (VUS=1)", "v28"), "Verdict (10% margin)"] == "different"


def test_suite_host_variance_stops_on_a_gated_mismatch_unless_allowed(tmp_path, monkeypatch):
    root = tmp_path / "results"
    make_suite_run(root, "hosta")
    make_suite_run(root, "hostb", host_provenance__irqbalance="active")
    out = tmp_path / "out"
    assert _main(suite_hv, monkeypatch, root, "--output-dir", out) == 1
    assert not list((out / "hostvariance" / "tables").glob("table_hv1_*"))
    assert _main(suite_hv, monkeypatch, root, "--output-dir", out, "--allow-env-mismatch") == 0
    [tex] = (out / "hostvariance" / "tables").glob("table_hv1_*.tex")
    assert "Compared despite differing gated environment fields: IRQ balancing." in tex.read_text()


def test_suite_host_variance_needs_two_usable_runs(tmp_path, monkeypatch, capsys):
    root = tmp_path / "results"
    make_suite_run(root, "hosta")
    bad = make_suite_run(root, "hostb")
    (bad / "run_failures_log.txt").write_text("baseline_28_rep1 k6 exit 99\n")
    no_metadata = make_suite_run(root, "hostc")
    (no_metadata / "run_metadata.json").unlink()
    assert _main(suite_hv, monkeypatch, root, "--output-dir", tmp_path / "out") == 1
    out = capsys.readouterr().out
    assert "failures log has entries" in out and "environment cannot be checked" in out


def test_ablation_host_variance_compares_cpuset_arms_by_cpu_count(tmp_path, monkeypatch):
    root = tmp_path / "results"
    make_ablation_run(root, "hosta")
    make_ablation_run(root, "hostb", python="16-21", speed=2.0,
                      isolation="python=16,18,20 java=22,24 k6=26,28", java="22-25", k6="26-29")
    assert _main(ablation_hv, monkeypatch, root, "--output-dir", tmp_path / "out") == 0
    summary = _table(tmp_path / "out", "table_ablation_hv1_effect_ratios")
    assert summary["Metric"].tolist() == ["CPU Cores: 2 CPUs vs 6 CPUs"] * 2
    assert set(summary["Same direction on every run"]) == {"yes"}
    assert summary.iloc[0]["Verdict (10% margin)"] == "equivalent"


def test_ablation_host_variance_detects_a_different_effect_size(tmp_path, monkeypatch):
    root = tmp_path / "results"
    make_ablation_run(root, "hosta", effect=3.0)
    make_ablation_run(root, "hostb", effect=1.5)
    assert _main(ablation_hv, monkeypatch, root, "--output-dir", tmp_path / "out") == 0
    summary = _table(tmp_path / "out", "table_ablation_hv1_effect_ratios").set_index("Family")
    assert summary.loc["Thread dispatch, extreme / control", "Verdict (10% margin)"] == "different"


# per-run analysis over several runs

def test_analyze_results_writes_each_run_to_its_own_folder_and_fails_on_a_rejected_one(tmp_path, monkeypatch):
    root = tmp_path / "results"
    good = make_suite_run(root, "hosta")
    bad = make_suite_run(root, "hostb")
    (bad / "run_failures_log.txt").write_text("scan_28_vus8_rep2 k6 exit 99\n")
    out = tmp_path / "out"
    assert _main(results, monkeypatch, "--results-dir", root, "--output-dir", out) == 1
    assert (out / "tables" / good.name / "table1_baseline_e2e_latency_pooled.csv").exists()
    assert not (out / "tables" / bad.name).exists()


def test_cpu_pin_log_counts_a_timed_out_k6_read_as_skipped_not_mismatched(tmp_path, capsys):
    (tmp_path / "cpu_pin_check_log.txt").write_text(
        "cpu_pin_check label=a k6_live=TIMEOUT k6_expected=10-11 result=WARN_SKIPPED_TIMEOUT\n"
        "cpu_pin_check label=a python_requested=0-1 python_live=0-1 java_requested=2-3 java_live=2-3\n")
    results.check_cpu_pin_log(str(tmp_path))
    out = capsys.readouterr().out
    assert "1 live cgroup cpuset check(s) were skipped" in out
    assert "2 checks verified, all matched" in out
