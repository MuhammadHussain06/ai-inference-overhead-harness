"""Cross-run comparison shared by analyze-host-variance.py and
analyze-ablation-host-variance.py: the environment gate that decides whether runs are
comparable at all, and the statistics that compare them.

Absolute latency and throughput differ between hosts by construction, so they are
reported as context and never tested. What is compared is ratios measured inside a
run -- a tier against the calibration floor, a stage against the Python total, an
ablation value against its arm's control -- paired by repetition, since the cells a
ratio compares were measured in the same rep. Each run's ratio gets a rep-level
bootstrap CI, and each pair of runs a bootstrap CI on their percent difference, read
as an equivalence test (TOST) against a margin fixed in advance.
"""

import hashlib
import json
import os
import re
import zlib
from itertools import combinations

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy import stats

from report import save_table
from run_dirs import METADATA_FILE

N_BOOT = 2000
SEED = 42
DEFAULT_MARGIN_PCT = 10.0
ALPHA = 0.05

ENV_TRACE_FILE = {"suite": "env_trace_log.txt", "ablation": "ablation_env_trace_log.txt"}
SERVICES = (("python", "python_service"), ("java", "transaction_service"), ("k6", "k6"))
IRQBALANCE = {"active": "on", "running_no_systemd_unit": "on",
              "inactive": "off", "failed": "off", "not_present": "off"}
POWER = {"ac": "mains", "no_mains_supply_exposed": "mains", "battery": "battery"}
TURBO = {"on": "on", "off": "off"}
# Longer values are shown abbreviated in the environment table and in full on the console.
MAX_DISPLAY_CHARS = 40
SHA256_RE = re.compile(r"(?:sha256:)?([0-9a-f]{12})[0-9a-f]{52}$")
ENV_CAPTION = ("Environment of each compared run. Gated fields must match for the runs to be compared; "
               "reported fields describe hardware and toolchain, which may differ. Service CPUs are "
               "compared by count and isolation level, not by CPU number; CPU power limits only between "
               "runs of one machine, since they are hardware-specific. Values over 40 characters are "
               "abbreviated.")
COLORS = ["#2b5c8f", "#c0392b", "#27ae60", "#8e44ad", "#e67e22", "#16a085"]


# Run labels

def run_labels(runs):
    """Each run's host label, with its timestamp appended where a host label repeats."""
    hosts = [r.host for r in runs]
    return [r.host if hosts.count(r.host) == 1 else f"{r.host}-{r.timestamp}" for r in runs]


def same_machine(a, b):
    """The same host label, and the same machine ID unless either run lacks one."""
    return a.host == b.host and (a.machine is None or b.machine is None or a.machine == b.machine)


def shares_machine(runs):
    """Whether two of the runs came from one machine."""
    return any(same_machine(a, b) for a, b in combinations(runs, 2))


# Environment gate

def usable_runs(runs, has_failures):
    """The runs that recorded metadata and no failure; each other run is named and dropped."""
    usable = []
    for run in runs:
        if not run.metadata:
            print(f"[!] {run.name}: no {METADATA_FILE[run.kind]}, so its environment cannot be checked -- excluded.")
        elif has_failures(run):
            print(f"[!] {run.name}: its failures log has entries -- excluded.")
        else:
            usable.append(run)
    return usable


def expand_cpuset(cpuset):
    cpus = set()
    for part in str(cpuset or "").split(","):
        part = part.strip()
        if not part or not part.replace("-", "").isdigit():
            continue
        lo, _, hi = part.partition("-")
        cpus.update(range(int(lo), int(hi or lo) + 1))
    return cpus


def _known(v):
    return None if v in (None, "") or str(v).startswith("unknown") else v


def _cores(run):
    return run.metadata.get("cores_used_by_suite") or {}


def _provenance(run):
    return run.metadata.get("host_provenance") or {}


def _power(run):
    return run.metadata.get("power_state") or {}


def _isolation_cores(run):
    text = str(_cores(run).get("physical_core_isolation", ""))
    fields = dict(tok.split("=", 1) for tok in text.split() if "=" in tok)
    if not all(svc in fields for svc, _ in SERVICES):
        return None
    return {svc: [c for c in fields[svc].split(",") if c and c != "EMPTY"] for svc, _ in SERVICES}


def isolation_status(run):
    """Whether the run verified its services' physical-core disjointness."""
    if str(_cores(run).get("physical_core_isolation", "")).startswith("unverifiable"):
        return "unverifiable"
    return "verified" if _isolation_cores(run) else None


def physical_cores(run):
    cores = _isolation_cores(run)
    return None if cores is None else " ".join(f"{svc}={len(cores[svc])}" for svc, _ in SERVICES)


def logical_cpus(run):
    counts = [_cores(run).get(f"{key}_cores") for _, key in SERVICES]
    if any(c is None for c in counts):
        return None
    return " ".join(f"{svc}={c}" for (svc, _), c in zip(SERVICES, counts))


def cpu_quotas(run):
    """Each service's CPU quota (compose cpus), which a .env override can change."""
    quotas = []
    for _, key in SERVICES:
        try:
            quotas.append(f"{float(_cores(run).get(f'{key}_cpus_quota')):g}")
        except (TypeError, ValueError):
            return None
    return " ".join(f"{svc}={q}" for (svc, _), q in zip(SERVICES, quotas))


def pinned_isolcpus(run):
    """How much of the services' pinned CPUs isolcpus covered: all, partial or none."""
    live = _provenance(run).get("isolcpus_live")
    if live in (None, "unreadable"):
        return None
    pinned = set()
    for _, key in SERVICES:
        pinned |= expand_cpuset(_cores(run).get(f"{key}_cpuset"))
    if not pinned:
        return None
    covered = pinned & expand_cpuset(live)
    return "all" if covered == pinned else ("partial" if covered else "none")


def governor(run):
    """CPU governor at run start, from the metadata or else the first env trace sample."""
    recorded = _known(run.metadata.get("cpu_governor_at_start"))
    if recorded:
        return recorded
    path = os.path.join(run.path, ENV_TRACE_FILE[run.kind])
    if os.path.isfile(path):
        with open(path, errors="replace") as f:
            for line in f:
                if line.startswith("env_sample"):
                    fields = dict(t.split("=", 1) for t in line.split() if "=" in t)
                    return _known(fields.get("governor"))
    return None


def _digest(value):
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def _display(value):
    """A SHA-256 value (fingerprint, image digest) as its first 12 hex digits; any other
    long value as "hash:" and the first 12 hex digits of its own SHA-256."""
    if value is None:
        return "unrecorded"
    text = str(value)
    if len(text) <= MAX_DISPLAY_CHARS:
        return text
    m = SHA256_RE.search(text)
    return m[1] if m else f"hash:{_digest(text)}"


def _version(text):
    """"Docker version 29.1.3, build ..." -> "29.1.3, build ..."."""
    text = _known(text)
    return re.sub(r"^.*?version\s+", "", text) if text else None


def _canonical(obj):
    return None if not obj else json.dumps(obj, sort_keys=True)


def environment_table(runs, labels, config_of):
    """Every gated and reported environment field per run. Gated fields must agree:
    "MISMATCH" where two runs recorded different values, "unverified" or "unrecorded"
    where some or all runs recorded none. Per-machine fields must agree only between runs
    of one machine. Reported fields describe the hardware and toolchain, which may differ. config_of(run) returns the run's design configuration
    with host-specific CPU numbers normalized away. Returns (table, mismatched fields,
    unverified fields)."""
    fingerprints = [_known(r.metadata.get("measurement_fingerprint")) for r in runs]
    if all(fingerprints):
        code = ("Measured code (fingerprint)", lambda r: _known(r.metadata.get("measurement_fingerprint")))
    else:
        code = ("Measured code (git commit)", lambda r: _known(r.metadata.get("git_commit")))
    gated = [
        code,
        ("Run configuration", lambda r: _canonical(config_of(r))),
        ("JVM pinned options", lambda r: _known(r.metadata.get("jvm_pinned_options"))),
        ("k6 image", lambda r: _known(r.metadata.get("k6_image"))),
        ("k6 image digest", lambda r: _known(r.metadata.get("k6_image_digest"))),
        ("Service CPUs (logical)", logical_cpus),
        ("Service CPU quotas", cpu_quotas),
        ("Service cores (physical)", physical_cores),
        ("Physical-core isolation", isolation_status),
        ("Pinned CPUs in isolcpus", pinned_isolcpus),
        ("IRQ balancing", lambda r: IRQBALANCE.get(_provenance(r).get("irqbalance"))),
        ("Power source", lambda r: POWER.get(_provenance(r).get("power_source"))),
        ("CPU governor", governor),
        ("Turbo", lambda r: TURBO.get(_power(r).get("turbo"))),
        ("WSL2", lambda r: _known(r.metadata.get("wsl2_detected"))),
        ("Virtualization", lambda r: _known(_provenance(r).get("virtualization"))),
    ]
    # Hardware-specific values that must still agree between runs of one machine.
    per_machine = [
        ("CPU power limits", lambda r: _known(_power(r).get("power_limits"))),
    ]
    reported = [
        ("Hostname", lambda r: r.metadata.get("hostname") or r.host),
        ("Machine ID (SHA-256 prefix)", lambda r: r.machine),
        ("CPU model", lambda r: _known(r.metadata.get("cpu_model"))),
        ("Logical CPUs", lambda r: _known(r.metadata.get("cpu_count"))),
        ("Memory (GB)", lambda r: (round(int(r.metadata["total_mem_kb"]) / 1048576, 1)
                                   if str(r.metadata.get("total_mem_kb", "")).isdigit() else None)),
        ("Kernel", lambda r: (str(r.metadata.get("host_uname", "")).split() + [None] * 3)[2]),
        ("Docker", lambda r: _version(r.metadata.get("docker_version"))),
        ("Docker Compose", lambda r: _version(r.metadata.get("docker_compose_version"))),
        ("git commit", lambda r: (_known(r.metadata.get("git_commit")) or "")[:12] or None),
        ("git dirty", lambda r: _known(r.metadata.get("git_dirty"))),
        ("Energy preference", lambda r: _known(_power(r).get("energy_preference"))),
        ("Power profile", lambda r: _known(_power(r).get("power_profile"))),
        ("thermald", lambda r: _known(_power(r).get("thermald"))),
    ]

    rows, mismatched, unverified = [], [], []
    entries = ([(True, False, f) for f in gated] + [(True, True, f) for f in per_machine]
               + [(False, False, f) for f in reported])
    for is_gated, machine_scoped, (field, extract) in entries:
        values = [extract(r) for r in runs]
        known = {str(v) for v in values if v is not None}
        clash = machine_scoped and any(
            same_machine(a, b) and va is not None and vb is not None and str(va) != str(vb)
            for (a, va), (b, vb) in combinations(zip(runs, values), 2))
        if not known:
            status = "unrecorded"
            if is_gated:
                unverified.append(field)
        elif not is_gated:
            status = "same" if len(known) == 1 else "differs"
        elif clash:
            status = "MISMATCH"
            mismatched.append((field, values))
        elif machine_scoped and any(v is None for v in values):
            status = "unverified"
            unverified.append(field)
        elif machine_scoped:
            status = "match" if len(known) == 1 else "differs between machines"
        elif len(known) > 1:
            status = "MISMATCH"
            mismatched.append((field, values))
        elif any(v is None for v in values):
            status = "unverified"
            unverified.append(field)
        else:
            status = "match"
        rows.append({"Field": field, **{lab: _display(v) for lab, v in zip(labels, values)},
                     "Status": status, "Gated": "yes" if is_gated else "no"})
    return pd.DataFrame(rows), mismatched, unverified


def apply_gate(runs, labels, config_of, out, table_name, table_label, allow_mismatch, caption=ENV_CAPTION):
    """Writes the environment table and returns the note every later caption carries, or
    None when a gated field differs and allow_mismatch is off."""
    env, mismatched, unverified = environment_table(runs, labels, config_of)
    save_table(env, table_name, out, caption=caption, label=table_label)
    note = ""
    if mismatched:
        for field, values in mismatched:
            print(f"[!] {field} differs between runs:")
            for lab, v in zip(labels, values):
                print(f"      {lab}: {v if v is not None else 'unrecorded'}")
        if not allow_mismatch:
            print(f"[!] The runs' environments differ ({table_name}), so their results are not "
                  "comparable. --allow-env-mismatch compares them anyway.")
            return None
        note = " Compared despite differing gated environment fields: " + ", ".join(f for f, _ in mismatched) + "."
    if unverified:
        print(f"[!] Not recorded by every run, so unverified: {', '.join(unverified)}.")
    if shares_machine(runs):
        print("[!] Some runs share a host; those comparisons measure between-run, not between-host, variance.")
        note += " Some compared runs share a host."
    return note


# Statistics

def _rep_key(rep):
    try:
        return 0, int(rep)
    except (TypeError, ValueError):
        return 1, str(rep)


def paired(num, den):
    """Per-rep numerator and denominator arrays over the reps both recorded."""
    reps = sorted(set(num) & set(den), key=_rep_key)
    a = np.array([num[r] for r in reps], dtype=float)
    b = np.array([den[r] for r in reps], dtype=float)
    keep = np.isfinite(a) & np.isfinite(b)
    return a[keep], b[keep]


def ratio_bootstrap(num, den, key):
    """Ratio of rep means and its bootstrap distribution, resampling whole reps with
    the pairing kept. The distribution is None below two reps."""
    a, b = paired(num, den)
    if len(a) == 0 or b.mean() == 0:
        return np.nan, None
    estimate = float(a.mean() / b.mean())
    if len(a) < 2:
        return estimate, None
    rng = np.random.default_rng([SEED, zlib.crc32("|".join(map(str, key)).encode())])
    idx = rng.integers(0, len(a), size=(N_BOOT, len(a)))
    with np.errstate(divide="ignore", invalid="ignore"):
        return estimate, a[idx].mean(axis=1) / b[idx].mean(axis=1)


def same_direction(series):
    """"yes" when every run's ratio lies on the same side of 1, else "no"."""
    signs = set()
    for num, den in series:
        a, b = paired(num, den)
        if len(a) and b.mean():
            signs.add(np.sign(a.mean() / b.mean() - 1))
    return "yes" if len(signs) == 1 else "no"


def equivalence_bounds(margin):
    """Percent-difference bounds of a margin applied to the ratio of two runs' values:
    within [1/(1+m), 1+m], symmetric on the log scale, so which run is the reference
    does not change a verdict. 10 gives (-9.09, 10)."""
    return 100 * (100 / (100 + margin) - 1), margin


def margin_text(margin):
    lower, upper = equivalence_bounds(margin)
    return f"{lower:.1f}% to +{upper:g}%"


def verdict_column(margin):
    return f"Verdict ({margin:g}% margin)"


def verdict(lo90, hi90, margin):
    """Equivalence (TOST at alpha=0.05: the 90% CI inside the bounds), a difference
    beyond them (the 90% CI entirely outside), or neither."""
    if not np.isfinite(lo90) or not np.isfinite(hi90):
        return "insufficient reps"
    lower, upper = equivalence_bounds(margin)
    if lower < lo90 and hi90 < upper:
        return "equivalent"
    if lo90 > upper or hi90 < lower:
        return "different"
    return "inconclusive"


def _overall(verdicts):
    if "insufficient reps" in verdicts:
        return "insufficient reps"
    if all(v == "equivalent" for v in verdicts):
        return "equivalent"
    if "different" in verdicts:
        return "different"
    return "inconclusive"


def _interval(lo, hi, digits):
    return f"[{lo:.{digits}f}, {hi:.{digits}f}]" if np.isfinite(lo) and np.isfinite(hi) else "n/a"


def compare(metrics, labels, margin):
    """metrics: dicts with "family", "metric" and "series" -- one (num, den) pair of
    {rep: value} dicts per run, in labels order. Returns (summary, pairwise) tables:
    each run's ratio with its 95% CI, the between-run coefficient of variation and an
    overall verdict per metric; and each pair's percent difference (second run relative
    to the first) with 90% and 95% CIs and its own verdict."""
    summary, pairwise = [], []
    for m in metrics:
        key = (m["family"], m["metric"])
        results = [ratio_bootstrap(num, den, key + (lab,)) for (num, den), lab in zip(m["series"], labels)]
        estimates = np.array([e for e, _ in results])
        row = {"Family": m["family"], "Metric": m["metric"]}
        for lab, (est, boot) in zip(labels, results):
            ci = np.nanpercentile(boot, [2.5, 97.5]) if boot is not None else (np.nan, np.nan)
            row[lab] = f"{est:.3f} {_interval(*ci, 3)}" if np.isfinite(est) else "n/a"
        finite = estimates[np.isfinite(estimates)]
        row["Between-run CoV (%)"] = (round(float(100 * finite.std(ddof=1) / finite.mean()), 2)
                                      if len(finite) > 1 and finite.mean() else np.nan)
        verdicts, max_abs = [], np.nan
        for (i, a), (j, b) in combinations(enumerate(labels), 2):
            (est_a, boot_a), (est_b, boot_b) = results[i], results[j]
            diff = 100 * (est_b / est_a - 1) if est_a else np.nan
            if boot_a is not None and boot_b is not None:
                # Percentiles taken on the log ratio, so swapping the runs negates them exactly.
                with np.errstate(divide="ignore", invalid="ignore"):
                    log_ratio = np.log(boot_b) - np.log(boot_a)
                lo90, hi90, lo95, hi95 = 100 * np.expm1(np.nanpercentile(log_ratio, [5, 95, 2.5, 97.5]))
            else:
                lo90 = hi90 = lo95 = hi95 = np.nan
            v = verdict(lo90, hi90, margin)
            verdicts.append(v)
            if np.isfinite(diff):
                max_abs = abs(diff) if not np.isfinite(max_abs) else max(max_abs, abs(diff))
            pairwise.append({"Family": m["family"], "Metric": m["metric"], "Pair": f"{b} vs {a}",
                             "Difference (%)": round(float(diff), 2) if np.isfinite(diff) else np.nan,
                             "90% CI (%)": _interval(lo90, hi90, 2), "95% CI (%)": _interval(lo95, hi95, 2),
                             verdict_column(margin): v,
                             "_lo90": lo90, "_hi90": hi90})
        row["Max |difference| (%)"] = round(float(max_abs), 2) if np.isfinite(max_abs) else np.nan
        row[verdict_column(margin)] = _overall(verdicts)
        summary.append(row)
    return pd.DataFrame(summary), pd.DataFrame(pairwise)


def kendalls_w(matrix):
    """Kendall's coefficient of concordance for a runs x items matrix, tie-corrected,
    with its chi-square test. Returns (W, chi-square, df, p)."""
    m = np.asarray(matrix, dtype=float)
    k, n = m.shape
    if k < 2 or n < 2:
        return np.nan, np.nan, n - 1, np.nan
    ranks = np.vstack([stats.rankdata(row) for row in m])
    s = float(((ranks.sum(axis=0) - k * (n + 1) / 2) ** 2).sum())
    ties = sum(float((c ** 3 - c).sum()) for c in (np.unique(row, return_counts=True)[1] for row in ranks))
    denom = k ** 2 * (n ** 3 - n) - k * ties
    if denom <= 0:
        return np.nan, np.nan, n - 1, np.nan
    w = 12 * s / denom
    chi2 = k * (n - 1) * w
    return w, chi2, n - 1, float(stats.chi2.sf(chi2, n - 1))


def kendalls_w_p_floor(k, n):
    """The smallest chi-square p-value k runs ranking n items can reach, that of identical
    orderings. Above alpha, the test cannot register agreement however close it is."""
    if k < 2 or n < 2:
        return np.nan
    return float(stats.chi2.sf(k * (n - 1), n - 1))


def saturation_level(levels, means, fraction=0.95):
    """Lowest level whose mean reaches fraction of the highest mean across levels."""
    pairs = [(lvl, v) for lvl, v in zip(levels, means) if np.isfinite(v)]
    if not pairs:
        return None
    top = max(v for _, v in pairs)
    return next(lvl for lvl, v in pairs if v >= fraction * top)


def fmt_p(p):
    if p is None or not np.isfinite(p):
        return np.nan
    return f"{p:.2e}" if p < 0.001 else round(float(p), 4)


def forest_figure(pairwise, margin, title):
    """Percent difference per metric and pair with its 90% CI, against the shaded
    equivalence bounds. None when no pair has a CI."""
    rows = pairwise.dropna(subset=["_lo90", "_hi90"]).reset_index(drop=True)
    if rows.empty:
        return None
    y = np.arange(len(rows))[::-1]
    lower, upper = equivalence_bounds(margin)
    fig, ax = plt.subplots(figsize=(8, max(3.0, 0.28 * len(rows) + 1.2)), dpi=300)
    ax.axvspan(lower, upper, color="#27ae60", alpha=0.12,
               label=f"equivalence bounds ({lower:.1f}% to +{upper:g}%)")
    ax.axvline(0, color="#333333", linewidth=0.8)
    diff = rows["Difference (%)"].to_numpy(dtype=float)
    lo = np.clip(diff - rows["_lo90"].to_numpy(dtype=float), 0, None)
    hi = np.clip(rows["_hi90"].to_numpy(dtype=float) - diff, 0, None)
    ax.errorbar(diff, y, xerr=[lo, hi], fmt="o", markersize=3,
                capsize=2, color="#2b5c8f", ecolor="#2b5c8f", label="difference, 90% CI")
    ax.set_yticks(y)
    several_pairs = rows["Pair"].nunique() > 1
    ax.set_yticklabels([f"{r.Family}: {r.Metric}" + (f" | {r.Pair}" if several_pairs else "")
                        for r in rows.itertuples()], fontsize=6)
    ax.set_xlabel("Difference between runs (%)")
    ax.set_title(title if several_pairs else f"{title}: {rows['Pair'].iloc[0]}", fontweight="bold", fontsize=9)
    ax.legend(fontsize=7, loc="lower right")
    ax.grid(True, axis="x", linestyle="--", alpha=0.4)
    return fig
