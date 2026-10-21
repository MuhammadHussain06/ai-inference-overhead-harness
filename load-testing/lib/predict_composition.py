"""Splits the model-inference field (the whole predict_proba call) into input conversion
and tree traversal, per tier, in-process. The service's telemetry times predict_proba as
one span, so this runs inside the python-service image (its locked pandas/xgboost) and
times, alternately on the same 1-row frame model.py builds:

  total      model.predict_proba(df), exactly as the service calls it;
  traversal  booster.predict on a pre-built DMatrix of that frame: tree evaluation plus
             the booster call, with no pandas conversion or feature-name validation;
  inplace    booster.inplace_predict on a pre-built float32 array, the dense form of the
             in-place path predict_proba takes, as a cross-check on traversal.

conversion = total - traversal. One invocation is one repetition: run-predict-composition.sh
starts a fresh container per rep, passes the tiers in that rep's shuffled order, and merges
the rep files on the host with --merge. Before measuring, the process checks its CPU
affinity and its cgroup CPU quota against the suite run's recorded values. Library imports
are deferred to measure() so the summary, quota and merge functions import without
xgboost for the unit tests and the host-side merge.

Usage: python3 predict_composition.py --out FILE [--rep N] [--models-dir DIR]
       [--tiers 5,10,20,28] [--n 2000] [--warmup 200] [--expect-cpuset LIST]
       [--expect-cpu-quota CPUS] [--image-id ID]
       python3 predict_composition.py --out FILE --merge REP_FILE...
"""

import argparse
import json
import os
import platform
import random
import sys
import time
from datetime import datetime, timezone

DEFAULT_TIERS = (5, 10, 20, 28)
# common.js always sends 28 features drawn from [-2, 2) and amount 100.0; a seeded draw
# from the same range keeps every tier and every run on one fixed input.
FEATURE_SEED = 20240501
FEATURE_COUNT = 28
AMOUNT = 100.0
NUMERIC_THREAD_ENV_VARS = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS")
STREAMS = ("total", "traversal", "inplace")
SCHEMA = 2
# Fields every rep of one merged file must share: a merged file describes one image, one
# workload and one library set.
SHARED_FIELDS = ("image_id", "n_calls", "warmup_calls", "feature_seed", "amount", "clock",
                 "numeric_thread_env", "versions")
DEFAULT_CGROUP_ROOT = "/sys/fs/cgroup"


def representative_features(seed=FEATURE_SEED, n=FEATURE_COUNT):
    rng = random.Random(seed)
    return [rng.random() * 4 - 2 for _ in range(n)]


def percentile(values, q):
    """Linear interpolation between closest ranks (numpy's default method)."""
    if not values:
        raise ValueError("percentile of an empty sample")
    s = sorted(values)
    pos = (len(s) - 1) * q / 100.0
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def describe(values_ms):
    return {"median": percentile(values_ms, 50), "p25": percentile(values_ms, 25),
            "p75": percentile(values_ms, 75), "n": len(values_ms)}


def summarize_tier(tier, samples_ms):
    """samples_ms: {stream: [ms, ...]} for STREAMS. Conversion is taken between medians,
    since per-call differences of two separately timed calls are not paired."""
    out = {"tier": tier}
    for stream in STREAMS:
        if stream in samples_ms:
            out[f"{stream}_ms"] = describe(samples_ms[stream])
    total = out["total_ms"]["median"]
    traversal = out["traversal_ms"]["median"]
    out["n"] = min(len(samples_ms["total"]), len(samples_ms["traversal"]))
    out["conversion_median_ms"] = total - traversal
    out["conversion_share"] = 1.0 - traversal / total if total > 0 else None
    return out


def parse_cpuset(text):
    cpus = set()
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            cpus.update(range(int(a), int(b) + 1))
        else:
            cpus.add(int(part))
    return cpus


def format_cpuset(cpus):
    return ",".join(str(c) for c in sorted(cpus))


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def read_cpu_quota(root=DEFAULT_CGROUP_ROOT):
    """The CPU limit the kernel enforces on this cgroup, as {"cpus", "source", "raw"}:
    cgroup v2 cpu.max ("<quota> <period>" or "max <period>"), else cgroup v1's CFS quota
    and period. cpus is None when unlimited. None when neither interface is readable."""
    raw = _read(os.path.join(root, "cpu.max"))
    if raw is not None:
        parts = raw.split()
        if len(parts) == 2 and parts[1].isdigit() and int(parts[1]) > 0:
            cpus = None if parts[0] == "max" else int(parts[0]) / int(parts[1])
            return {"cpus": cpus, "source": "cgroup v2 cpu.max", "raw": raw}
    for sub in ("cpu", "cpu,cpuacct", ""):
        quota = _read(os.path.join(root, sub, "cpu.cfs_quota_us"))
        period = _read(os.path.join(root, sub, "cpu.cfs_period_us"))
        if quota is None or period is None:
            continue
        try:
            q, per = int(quota), int(period)
        except ValueError:
            continue
        if per > 0:
            return {"cpus": None if q < 0 else q / per, "source": "cgroup v1 cpu.cfs_quota_us",
                    "raw": f"{quota} {period}"}
    return None


def check_cpu_quota(expected, root=DEFAULT_CGROUP_ROOT, tol=1e-3):
    """Compares the enforced CPU limit with the suite's recorded quota. status is
    "verified", "mismatch" (including an unlimited cgroup) or "unverifiable" when the
    cgroup exposes no quota file."""
    observed = read_cpu_quota(root)
    if observed is None:
        return {"status": "unverifiable", "expected": expected, "observed": None,
                "source": None, "reason": "no cgroup CPU quota file is readable"}
    cpus = observed["cpus"]
    ok = cpus is not None and abs(cpus - expected) <= tol
    return {"status": "verified" if ok else "mismatch", "expected": expected,
            "observed": "max" if cpus is None else round(cpus, 6),
            "source": observed["source"], "raw": observed["raw"]}


def merge_reps(rep_docs):
    """One schema-2 report from per-rep documents, ordered by rep. Raises ValueError when
    the reps disagree on a SHARED_FIELDS value or repeat a rep number."""
    if not rep_docs:
        raise ValueError("no rep files to merge")
    docs = sorted(rep_docs, key=lambda d: int(d["rep"]))
    reps = [int(d["rep"]) for d in docs]
    if len(set(reps)) != len(reps):
        raise ValueError(f"duplicate rep numbers: {reps}")
    first = docs[0]
    for field in SHARED_FIELDS:
        values = {json.dumps(d.get(field), sort_keys=True) for d in docs}
        if len(values) > 1:
            raise ValueError(f"reps disagree on {field}: {sorted(values)}")
    report = {"schema": SCHEMA,
              "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "n_reps": len(docs)}
    report.update({field: first.get(field) for field in SHARED_FIELDS})
    report["reps"] = [{k: d.get(k) for k in ("rep", "generated_utc", "tier_order", "cpu_affinity",
                                             "cpu_quota", "tiers")} for d in docs]
    return report


def write_json(path, doc):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def build_frame(pd, np, columns, features, amount):
    """The request DataFrame as FraudMLTier.predict builds it."""
    n = len(columns) - 1
    row = list(features[:n]) + [np.log1p(amount)]
    return pd.DataFrame([row], columns=columns)


def measure_tier(tier, model, xgb, pd, np, features, n_calls, warmup):
    model.set_params(n_jobs=1)
    n_jobs = getattr(model, "n_jobs", None)
    columns = [f"V{i}" for i in range(1, tier + 1)] + ["Amount"]
    df = build_frame(pd, np, columns, features, AMOUNT)
    booster = model.get_booster()
    # The trees predict_proba evaluates (all of them unless trained with early stopping).
    iteration_range = model._get_iteration_range(None)
    dmat = xgb.DMatrix(df, feature_names=columns, nthread=1)
    dense = np.ascontiguousarray(df.to_numpy(dtype=np.float32))

    calls = {
        "total": lambda: model.predict_proba(df),
        "traversal": lambda: booster.predict(dmat, output_margin=False, validate_features=False,
                                             iteration_range=iteration_range),
        "inplace": lambda: booster.inplace_predict(dense, iteration_range=iteration_range,
                                                   predict_type="value", missing=model.missing,
                                                   validate_features=False),
    }
    p_total = float(calls["total"]()[0][1])
    p_traversal = float(calls["traversal"]()[0])
    p_inplace = float(calls["inplace"]()[0])

    for _ in range(warmup):
        for fn in calls.values():
            fn()

    samples = {s: [] for s in STREAMS}
    clock = time.perf_counter
    # Rotating the order each iteration spreads drift and cache effects over all streams.
    for i in range(n_calls):
        for k in range(len(STREAMS)):
            stream = STREAMS[(i + k) % len(STREAMS)]
            fn = calls[stream]
            t0 = clock()
            fn()
            samples[stream].append((clock() - t0) * 1000.0)

    out = summarize_tier(tier, samples)
    out.update({
        "n_jobs": n_jobs,
        "iteration_range": list(iteration_range),
        "num_boosted_rounds": booster.num_boosted_rounds(),
        "score_predict_proba": p_total,
        "max_abs_score_diff": max(abs(p_total - p_traversal), abs(p_total - p_inplace)),
    })
    return out


def measure(args):
    """One repetition in this process: the guards, then every tier in --tiers order."""
    affinity = os.sched_getaffinity(0) if hasattr(os, "sched_getaffinity") else set()
    if args.expect_cpuset and affinity != parse_cpuset(args.expect_cpuset):
        print(f"[!] Running on CPUs {format_cpuset(affinity)}, expected {args.expect_cpuset}.", file=sys.stderr)
        return 1
    quota = None
    if args.expect_cpu_quota is not None:
        quota = check_cpu_quota(args.expect_cpu_quota, args.cgroup_root)
        if quota["status"] == "mismatch":
            print(f"[!] The cgroup CPU limit is {quota['observed']} ({quota['source']}: {quota['raw']}), "
                  f"expected {args.expect_cpu_quota} from the suite run.", file=sys.stderr)
            return 1
        if quota["status"] == "unverifiable":
            print("[!] No cgroup CPU quota file is readable; the CPU quota is recorded as unverifiable.",
                  file=sys.stderr)

    import joblib
    import numpy as np
    import pandas as pd
    import sklearn
    import xgboost as xgb

    features = representative_features()
    tier_order = [int(t) for t in args.tiers.split(",") if t.strip()]
    tiers = []
    for tier in tier_order:
        path = os.path.join(args.models_dir, f"fraud_model_v{tier}.joblib")
        model = joblib.load(path)
        result = measure_tier(tier, model, xgb, pd, np, features, args.n, args.warmup)
        if result["n_jobs"] != 1:
            print(f"[!] v{tier} model reports n_jobs={result['n_jobs']} after pinning, expected 1.", file=sys.stderr)
            return 1
        tiers.append(result)
        print(f"[*] rep {args.rep} v{tier}: total {result['total_ms']['median']:.4f} ms, traversal "
              f"{result['traversal_ms']['median']:.4f} ms, conversion share {result['conversion_share']:.1%}")

    report = {
        "schema": SCHEMA,
        "kind": "rep",
        "rep": args.rep,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tier_order": tier_order,
        "image_id": args.image_id or "unknown",
        "n_calls": args.n,
        "warmup_calls": args.warmup,
        "feature_seed": FEATURE_SEED,
        "amount": AMOUNT,
        "clock": "time.perf_counter",
        "cpu_affinity": format_cpuset(affinity),
        "cpu_quota": quota,
        "numeric_thread_env": {v: os.getenv(v) for v in NUMERIC_THREAD_ENV_VARS},
        "versions": {"python": platform.python_version(), "xgboost": xgb.__version__,
                     "pandas": pd.__version__, "numpy": np.__version__,
                     "scikit_learn": sklearn.__version__, "joblib": joblib.__version__},
        "tiers": tiers,
    }
    write_json(args.out, report)
    print(f"[+] predict_proba composition rep {args.rep} -> {args.out}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--merge", nargs="+", metavar="REP_FILE",
                    help="merge per-rep files into --out instead of measuring")
    ap.add_argument("--rep", type=int, default=1)
    ap.add_argument("--models-dir", default=os.getenv("MODEL_DIR", "models"))
    ap.add_argument("--tiers", default=",".join(str(t) for t in DEFAULT_TIERS))
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--expect-cpuset", default="")
    ap.add_argument("--expect-cpu-quota", type=float, default=None)
    ap.add_argument("--cgroup-root", default=DEFAULT_CGROUP_ROOT)
    ap.add_argument("--image-id", default="")
    args = ap.parse_args(argv)

    if args.merge:
        try:
            docs = []
            for path in args.merge:
                with open(path) as f:
                    docs.append(json.load(f))
            report = merge_reps(docs)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"[!] Could not merge the rep files: {e}", file=sys.stderr)
            return 1
        write_json(args.out, report)
        print(f"[+] predict_proba composition, {report['n_reps']} rep(s) -> {args.out}")
        return 0

    if args.n < 1 or args.warmup < 0 or args.rep < 1:
        ap.error("--n and --rep must be >= 1 and --warmup >= 0")
    return measure(args)


if __name__ == "__main__":
    sys.exit(main())
