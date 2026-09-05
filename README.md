# AI Inference Overhead Harness

A containerized testbed that measures the **latency and throughput cost of a live AI fraud-inference call**, benchmarked against a network-equivalent mock and a zero-work calibration floor.

```bash
# Recommended sequence
cd load-testing
./run-smoke-test.sh                          # pipeline check before committing to a full run
./run-suite.sh                               # baseline + concurrency scan, all reps
# optional: open-loop validity check (see Running)
./run-ablation.sh                            # thread-dispatch mechanism sweep (post-suite)
python3 ../analysis/analyze-results.py       # main suite tables + figures
python3 ../analysis/analyze-ablation.py      # ablation tables + figures
```

---

## Table of Contents

- [Idea](#idea)
- [Scope](#scope)
- [Architecture](#architecture)
- [Features](#features)
- [Dataset](#dataset)
- [API](#api)
- [Containerization & Hardware](#containerization--hardware)
- [Running](#running)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Structure](#structure)
- [Credits](#credits)

---

## Idea

Every transaction is scored by one of three strategies, sharing the same JVM, network hop, and DTOs:

| Strategy | What it does | Purpose |
|---|---|---|
| `DISTRIBUTED_AI_SYNCHRONOUS` | Scores with a real XGBoost model at a chosen feature-count tier (`V5`/`V10`/`V20`/`V28`) | Measures actual inference cost |
| `DISTRIBUTED_MOCK_GATEWAY` | Random-value mock, same request/response shape and network path as the real call | Network-equivalent baseline |
| `DISTRIBUTED_CALIBRATION_ONLY` | No business logic at all, not even a random draw | Isolates the harness's own instrumentation floor |

This separation lets you attribute latency precisely:

- **Mock − Calibration** ≈ cost of one random draw
- **AI tier − Calibration** ≈ DataFrame construction + model inference
- DB persistence (`APP_DB_SAVE_ENABLED=false`) is off for all benchmark runs, so writes never enter the measured path
- In-memory H2, so every run starts from a clean slate

---

## Scope

**This testbed answers:** in a synchronous, single-node, single-request microservice call, how much of end-to-end latency is model compute versus everything else (network, framework, serialization, queueing), and how that ratio shifts with model complexity (feature-tier) and concurrency.

**Out of scope:** batched or dynamic-batching inference cost (every call is a single row in, single prediction out; see [Limitations](#limitations)), multi-model or multi-tenant serving, GPU-backed inference, multi-region/network-hop latency, and production fraud-detection accuracy. Accuracy is never measured; the fraud-detection model is an incidental stand-in workload chosen for its four-tier feature-count structure.

---

## Architecture

```
k6 load generator
        │
        ▼
transaction-service (Java, Spring Boot 3 / WebFlux, Netty, H2 via R2DBC)
        │
        │  WebClient (non-blocking)
        │    POST /predict/v{5,10,20,28}  → real inference, tier-selected
        │    POST /predict/mock           → baseline
        │    POST /predict/calibrate      → zero-work floor
        ▼
fraud-ml-service (Python, FastAPI / Uvicorn, XGBoost registry)
```

Each service runs in its own container, pinned to a disjoint CPU range, so they never contend for cores during a run.

---

## Features

<details>
<summary><b>Routing and tiers</b></summary>

- Three-way strategy routing (`AI` / `mock` / `calibration`), selected per request via `strategy`.
- Four feature-count tiers for the AI strategy (`5`/`10`/`20`/`28`), selected via `featureTier`, routed to `/predict/v{tier}`. Each tier is its own XGBoost model, loaded once at startup and held in memory.
- The `calibration` target runs the full pipeline with zero computation behind it.
</details>

<details>
<summary><b>Telemetry</b></summary>

- Stage-by-stage latency nested in every response: parsing, network, DB write, response build, serialization (Java); parsing, thread dispatch, DataFrame construction, model inference, compute stall, serialization (Python).
- Timeouts/connection errors (`status=0`) tracked separately from HTTP errors.
- Client-side connection contention (`http_req_blocked`) reported as its own diagnostic, so a throughput plateau can be checked against the load generator before blaming server capacity.
- `/health` exposes `loadedTiers`, `nJobsVerified`, and `threadLimiterTokens` (live AnyIO thread-limiter capacity, verified per rep by `run-ablation.sh`).
</details>

<details>
<summary><b>Isolation and verification</b></summary>

- Reactive Java stack end to end (WebFlux + R2DBC).
- CPU pinning verified per repetition against each container's live cgroup cpuset, rather than only the requested Compose configuration.
- Model inference pinned to `n_jobs=1`, read back and verified, exposed on `/health` as `nJobsVerified`. `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, `NUMEXPR_NUM_THREADS` all pinned to 1.
- The valid feature-tier set is fetched from `fraud-ml-service`'s `/health` at startup instead of being hardcoded in Java. `run-suite.sh` re-verifies this per rep (`loadedTiers` matches expected, `nJobsVerified` all true) and aborts the suite if it doesn't.
- Outbound Java→Python connection pool is explicitly sized (`python.service.max-connections`, default `128`) and logged at startup.
- In-memory H2, clean slate every run.
- Per-request logging is off on both services (Java: `TransactionService` at `WARN`; Python: `uvicorn --no-access-log`), because a synchronous stdout write on the WebFlux event loop or the request coroutine would otherwise stall it, adding latency and throughput noise unrelated to inference.
- JVM GC events are logged continuously to `results/gc-logs/gc_<phase>_rep<N>.log` (one file per rep, archived by `run-suite.sh` before the next rep's JVM overwrites `gc.log`), so tail-latency spikes can be cross-checked against GC pauses.
</details>

<details>
<summary><b>Orchestration and analysis</b></summary>

- `run-suite.sh`: full baseline + concurrency-scan suite across clean-slate restarts, with per-repetition target/concurrency shuffling, CPU-pin verification, host/toolchain provenance fingerprinting, and a failures log. Any cell failure aborts the whole suite immediately rather than being logged and skipped.
- `run-ablation.sh`: thread-dispatch mechanism sweep at TARGET=28 VUS=64. Sweeps three arms one at a time (AnyIO thread-limiter tokens, python-service cpuset/core count, Uvicorn worker count) while holding the other two at a control value, using the same clean-slate-per-rep methodology as `run-suite.sh`. Run after the main suite.
- `warm-up.js`: JIT/pool warm-up once per restart, hitting every target sequentially in its own window (plus a second max-VUS pass before the concurrency scan). Shares code with `run-target.js` so warm-up traffic is tagged and classified identically to measured traffic.
- `analyze-results.py`: P50/P95/P99 tables and histograms per strategy/tier, Mann-Whitney U significance testing (Holm-Bonferroni corrected, rank-biserial effect sizes), cluster-level bootstrap CIs, reproducibility (CoV% across reps), paired error/timeout tables, client-contention diagnostics, warm-up convergence checks, throughput-vs-concurrency figures, and an optional open-loop-vs-closed-loop validity check when `openloop_*.json` files are present.
- `analyze-ablation.py`: decomposition table and stacked-bar figure per ablation arm, plus a rep-level Mann-Whitney test (control vs. most extreme value per arm) for Thread Dispatch time.
</details>

---

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud), anonymized European transactions from September 2013.

- Each tier uses the first `n` of 28 `V` PCA components (`V1..Vn`) plus `Amount` (`log1p`-transformed). `V10` is a strict superset of `V5`, and so on.
- Highly imbalanced (~0.17% fraud); trained with SMOTE oversampling, then `XGBClassifier`, independently per tier.
- Pretrained models for all four tiers are committed under `services/fraud-ml-service/models/`, so `docker compose up` works with no training step.
- `creditcard.csv` isn't bundled (Kaggle license). To retrain: place it at `services/fraud-ml-service/training/data/creditcard.csv`, or pass `--synthetic` for a structural smoke test only.

```bash
# train one tier
training/train_model.py --n-features {5,10,20,28}

# omit the flag to train all four → models/fraud_model_v{n}.joblib
```

The Python service loads whichever tiers are listed in `FEATURE_TIERS` (default `5,10,20,28`) and refuses to start if a listed tier's `.joblib` is missing.

---

## API

### Request

Clients always send the full `V1..V28` vector, regardless of tier; each endpoint slices what it needs, so one request body works against any tier. Mock and calibration ignore `features` entirely.

```
POST /api/v1/transactions
Content-Type: application/json
```

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "accountId": "ACC-12345",
  "amount": 12500.50,
  "transactionType": "WIRE_TRANSFER",
  "features": [2.8, -1.2, 0.5, 1.8, -0.8, "... up to V28"],
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10
}
```

- `featureTier` selects the model (`V5`/`V10`/`V20`/`V28`); required for `DISTRIBUTED_AI_SYNCHRONOUS`, ignored otherwise.
- `features` must contain at least `featureTier` values.
- `transactionId` must be a UUID; `accountId` must match `ACC-\d{4,10}`, both validated before reaching the AI layer. Invalid requests get a `400` with per-field errors.

### Response

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "riskScore": 0.9123,
  "transactionStatus": "FLAGGED",
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10,
  "executionTimeMs": 14.7,
  "requestParsingTimeMs": 0.03,
  "aiCallRoundTripTimeMs": 8.9,
  "estimatedNetworkOverheadMs": 6.59,
  "dbWriteTimeMs": 2.1,
  "responseObjectBuildTimeMs": 0.05,
  "pythonTelemetry": {
    "parsingRequestTimeMs": 0.21,
    "threadDispatchTimeMs": 0.15,
    "computationTimeMs": 1.85,
    "dataframeConstructionTimeMs": 1.23,
    "modelInferenceTimeMs": 0.62,
    "computeStallMs": 0.05,
    "serializationResponseTimeMs": 0.09,
    "totalPythonExecutionTimeMs": 2.30
  }
}
```

**Java-side fields**

| Field | Meaning |
|---|---|
| `requestParsingTimeMs` | Parse/validate the incoming DTO |
| `aiCallRoundTripTimeMs` | Full Java-side timing of the call to `fraud-ml-service` |
| `estimatedNetworkOverheadMs` | `aiCallRoundTripTimeMs` minus Python's `totalPythonExecutionTimeMs`: transit, FastAPI routing, queuing, outbound-pool wait |
| `dbWriteTimeMs` | `0.0` when `APP_DB_SAVE_ENABLED=false` (required for benchmarks) |
| `responseObjectBuildTimeMs` | Time to assemble the final `ResponseDto` |
| `executionTimeMs` | Full Java-side duration, timestamped from the WebFlux filter chain (`RequestTimingWebFilter`), so it includes Netty/WebFlux routing |

**Python-side fields (`pythonTelemetry`)**

| Field | Meaning |
|---|---|
| `parsingRequestTimeMs` | Request parsing/validation |
| `threadDispatchTimeMs` | Thread-pool queueing before the handler runs (measured for all three strategies) |
| `computationTimeMs` | `dataframeConstructionTimeMs` + `modelInferenceTimeMs`; `0.0` for mock/calibration |
| `dataframeConstructionTimeMs` | Time to build the single-row pandas `DataFrame` |
| `modelInferenceTimeMs` | Time inside `model.predict_proba` |
| `computeStallMs` | Portion of compute time the thread was off-CPU (GIL/OS scheduling) |
| `serializationResponseTimeMs` | Estimated response-serialization cost |
| `totalPythonExecutionTimeMs` | Total self-reported Python execution time |

> `serializationResponseTimeMs` and `totalPythonExecutionTimeMs` are estimates: a response can't report the cost of serializing itself without a prior serialization pass.

---

## Containerization & Hardware

| | python-service | transaction-service | k6 (load generator) |
|---|---|---|---|
| Image | `python:3.11-slim` | build `eclipse-temurin:21-jdk-alpine`, run `21-jre-alpine` | `grafana/k6` |
| Port | `8000` | `8080` | — |
| Cores | `0-2` (overridable by ablation cpuset arm) | `3-5` | `6-7` |
| Limit / reserved | 3.0 CPU / 3G RAM (1.0 / 1G) | 3.0 CPU / 3G RAM (1.0 / 1G) | 2.0 CPU / 1G RAM |
| Notes | `UVICORN_WORKERS=3` at benchmark time (overridable by ablation workers arm); `n_jobs=1` + BLAS env vars keep each `predict_proba` call single-threaded, independent from the worker concurrency | Outbound pool to Python sized via `python.service.max-connections` (default `128`); must stay ≥ highest VUS in `run-suite.sh`'s `CONCURRENCY_LEVELS` (currently `64`), or queueing inflates `estimatedNetworkOverheadMs`. Feature-tier set fetched from Python's `/health` at startup, retrying up to 60s. Heap fixed via `JAVA_TOOL_OPTIONS=-Xms1536m -Xmx1536m` for reproducible sizing across hosts/reps | Runs in its own container on a disjoint cpuset. Gated behind the `loadgen` Compose profile; invoked per-cell by `run-suite.sh` via `docker compose run`, not started by `docker compose up` |

Resource limits (`mem_limit`/`mem_reservation`/`cpus`) use Compose's plain (non-Swarm) top-level keys rather than `deploy.resources.limits`, which is a Swarm-only directive silently unenforced by `docker compose up`.

**Requirements**

- Docker + Docker Compose v2 (`docker compose`)
- 8+ logical cores (`cpuset` hardcoded to `0-2`/`3-5`/`6-7` across the three containers; adjust or drop on smaller machines)
- ~7GB free RAM for the suite; the analysis step may need more on a full dataset (see Troubleshooting)
- k6 runs containerized (`grafana/k6`, pulled automatically on first `run-suite.sh` invocation), so no host install is needed
- Python 3 on the host, required by `run-suite.sh` and `run-ablation.sh` for tier/limiter verification, plus `pip install -r analysis/requirements.txt` (pandas, numpy, matplotlib, scipy, statsmodels, tabulate, jinja2) for the analysis phase. `requirements.txt` sets minimum versions rather than exact pins.
- No GPU required

---

## Running

### Smoke test (recommended first)

A fast, reduced-scale pass (2 targets, 2 concurrency levels, 2 reps, reduced iteration counts) through the same pipeline the full suite uses. Catches structural problems in minutes rather than hours into a real run. Also fires one deliberately over-rate open-loop request to confirm `dropped_iterations` is detected.

```bash
docker compose build
pip install -r analysis/requirements.txt
cd load-testing
./run-smoke-test.sh
```

Check `run_failures_log.txt` and `cpu_pin_check_log.txt` afterward, and confirm `table7_openloop_validity_check` shows a nonzero dropped-iterations count for the smoke-openloop cell. A clean pass means the pipeline is trustworthy; it says nothing about whether any given rep count is sufficient. Re-run after any fix until it passes, then move to the full suite.

`run-suite.sh`'s `TARGETS`, `CONCURRENCY_LEVELS`, `REPS_BASELINE`, `REPS_SCAN`, `BASELINE_ITERATIONS`, and `SCAN_ITERATIONS_PER_VU` are all overridable via `TARGETS_OVERRIDE`, `CONCURRENCY_OVERRIDE`, `REPS_BASELINE_OVERRIDE`, `REPS_SCAN_OVERRIDE`, `BASELINE_ITERATIONS_OVERRIDE`, and `SCAN_ITERATIONS_PER_VU_OVERRIDE` env vars. `run-smoke-test.sh` is a thin wrapper that sets these to a small slice.

### Full suite

Restarts the stack per repetition, shuffles order, logs provenance.

```bash
cd load-testing
./run-suite.sh
```

Requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`.

`run-suite.sh` runs `warm-up.js` at the start of every restart (plus an extra max-VUS pass before the concurrency scan), then drives `run-target.js` per target/concurrency cell across `mock`, `calibration`, and the four AI tiers. Output written to `results/`:

| File | Contents |
|---|---|
| `*.json` | One file per (target, concurrency, rep) cell |
| `run_order_log.txt` | Shuffle order per repetition |
| `run_metadata.json` | Timestamp, Docker/Compose versions, git commit + dirty flag, CPU model/count, pinned-core counts per service (`cores_used_by_suite`), CPU governor/frequency snapshot, `wsl2_detected` |
| `cpu_pin_check_log.txt` | Per-repetition requested-vs-live cpuset and JVM effective CPU count |
| `warmup_*_rep{N}.json` | Warm-up latency, tagged `phase=warmup`, for convergence checks |
| `gc-logs/gc_<phase>_rep{N}.log` | JVM GC events for that rep's transaction-service lifetime |

Previous runs are automatically archived to `results/archive/<timestamp>/` at the start of each new run, so old cells never mix into a fresh analysis pass.

### CPU pinning verification

`cpuset` in `docker-compose.yml` states what pinning was requested; it doesn't guarantee the cgroup driver honored it. Each repetition, `run-suite.sh` compares:

- **Requested**: `docker inspect --format '{{.HostConfig.CpusetCpus}}'`
- **Live**: `docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective` (cgroup v2, falling back to the v1 path)

A mismatch or empty value aborts the whole suite immediately. No results are written for that rep, and prior reps already on disk are unaffected.

`run-suite.sh` also verifies python-service's feature-tier loading each rep, via `/health`: `loadedTiers` must match `5,10,20,28` and `nJobsVerified` must be true for every tier. A silent tier-load failure would otherwise corrupt AI-tier cells without appearing as a request-level error. This has the same abort behavior as a cpu-pin mismatch.

Any cell failure (dropped connection, transient error, OOM kill) aborts the suite rather than being logged and skipped. `analyze-results.py` rejects the whole dataset if `run_failures_log.txt` has any entries, so continuing past the first failure gains nothing.

### Open-loop validity check (optional)

The main suite's concurrency scan is closed-loop (see [Limitations](#limitations)). `run-target-openloop.js` runs the same target under a `constant-arrival-rate` executor instead, so requests fire on a fixed schedule regardless of how fast responses come back. Run it against the top 1 to 2 concurrency cells after the main suite, as a check on whether the closed-loop tail-latency numbers hold up:

```bash
docker compose up
k6 run load-testing/warm-up.js
TARGET=28 RATE=32 TIME_UNIT=1s DURATION=2m PRE_ALLOCATED_VUS=64 MAX_VUS=128 \
  k6 run --out json=results/openloop_28_rate32.json load-testing/run-target-openloop.js
```

`RATE` is requests per `TIME_UNIT`. Set it to roughly the throughput the closed-loop cell achieved at that VUS level rather than the VUS count itself. `PRE_ALLOCATED_VUS`/`MAX_VUS` must be generous enough to sustain `RATE` if response times climb. A `dropped_iterations` warning from k6 means the server can't sustain that arrival rate, which is itself a finding. This script is standalone and manual; `run-suite.sh` never invokes it.

Output filenames must start with `openloop` (e.g. `openloop_28_rate32.json`). `analyze-results.py` detects any such files in `--results-dir` and, if present, adds `table7_openloop_validity_check` and `figure7_openloop_validity_check` comparing open-loop P95/P99 against the closed-loop scan at VUS 32/64. If no `openloop_*` files are present, this step is skipped silently.

### Thread-dispatch mechanism ablation

After the main suite, `run-ablation.sh` isolates which mechanism drives Thread Dispatch time at the highest concurrency cell (TARGET=28, VUS=64) by sweeping one candidate cause at a time while holding the other two at a fixed control value.

Three arms:

| Arm | What it varies | Control values held fixed |
|---|---|---|
| `thread_limiter` | AnyIO thread-limiter tokens: `{40, 64, 128}` | cpuset=0-2, workers=1 |
| `cpuset` | python-service core count: `{0-2, 8-13, 8-15}` (3/6/8 cores) | workers=1, thread_limiter=40 |
| `workers` | Uvicorn worker count: `{1, 2, 3}` | cpuset=0-2, thread_limiter=40 |

`thread_limiter` and `cpuset` fix `UVICORN_WORKERS=1` to isolate their mechanism without a multi-process confound. Their absolute Thread Dispatch numbers therefore won't match figure5 (recorded at workers=3); only the workers=3 cell in the workers arm is directly comparable to it.

```bash
cd load-testing
./run-ablation.sh
python3 ../analysis/analyze-ablation.py
```

Output files use `ablation_` prefixes (`ablation_run_metadata.json`, `ablation_run_failures_log.txt`, `ablation_cpu_pin_check_log.txt`, `ablation_<arm>_<value>_rep<N>.json`) so they never mix with the main suite's dataset. `analyze-ablation.py` reads only `ablation_*.json` files and writes to `analysis/output/tables/` and `analysis/output/figures/` alongside the main suite's output.

### Analyze results

```bash
python3 analysis/analyze-results.py    # reads results/*.json
python3 analysis/analyze-ablation.py   # reads results/ablation_*.json
```

Both scripts default to `../results` as `--results-dir` and `./output` as `--output-dir`. `analyze-results.py` refuses to run if `run_failures_log.txt` has any entries. `analyze-ablation.py` refuses to run if `ablation_run_failures_log.txt` has any entries.

### Manual / one-off run

```bash
docker compose up
k6 run load-testing/warm-up.js
k6 run --out json=results/results.json your-test.js
python3 analysis/analyze-results.py
```

`warm-up.js` is tunable via `WARMUP_ITERATIONS_PER_TARGET`, `WARMUP_VUS`, `WARMUP_MAX_DURATION_S`, and reads `BASE_URL` (falls back to `http://localhost:8080/api/v1/transactions`).

### Troubleshooting

- **`permission denied` writing to `/results/*.json` from inside the k6 container.** The `grafana/k6` image runs as a non-root user internally, so a host `results/` directory with default permissions can block its writes on a bind mount. Fix with `chmod -R 777 results/` before running.
- **`Conflict. The container name "/..." is already in use`** on `docker compose up`. Leftover stopped containers from an earlier interrupted run are holding a name. Run `docker ps -a`, then `docker rm` the stale container(s), then retry.
- **`pip install -r analysis/requirements.txt` fails building from source.** This usually means no prebuilt wheel exists for your Python version at these minimums, more likely on very new or very old CPython. Upgrading pip first (`pip install --upgrade pip`) often surfaces a compatible wheel. If it still falls back to a source build and fails, installing without version constraints (`pip install pandas numpy matplotlib scipy tabulate statsmodels jinja2`) is a safe fallback, since the analysis phase isn't sensitive to exact versions.
- **`analyze-results.py` runs out of memory on a full-suite dataset.** The script loads baseline/warmup and scan/openloop data in two separate passes to keep peak memory down, but a large raw results directory can still need several GB of headroom. On WSL2, the effective memory ceiling for everything running under WSL2 comes from `.wslconfig` (`%UserProfile%\.wslconfig`, `[wsl2]` section, `memory=`). Raise that value and run `wsl --shutdown` from Windows for it to take effect.
- **Docker or Compose issues in general** (daemon unreachable, `docker compose` vs `docker-compose`, WSL2-specific PATH quirks) are environment setup. Consult Docker's own docs for your OS if `docker info` itself isn't working.

---

## Limitations

- **Single-node only.** No multi-region or network-hop simulation.
- **"Network overhead" means Docker bridge-network overhead.** `estimatedNetworkOverheadMs` reflects the bridge/NAT path between two containers on one host, plus a small serialization-estimation error.
- **k6 is pinned to cpuset `6-7`, separate from python-service (`0-2`) and transaction-service (`3-5`), and verified live each rep.** This stops k6 from directly contending with the services under test for cgroup-level scheduling slots. It does not isolate any of the three from the Docker daemon or the rest of the host OS, which remain unpinned.
- **`http_req_blocked` diagnostics are a partial check only.** They can't independently prove k6 never became the bottleneck at high concurrency.
- **k6 is capped at 2 CPUs.** At high VUS counts, check `http_req_blocked` before trusting results, since a resource-starved load generator can look like service degradation.
- **The main suite's load model is closed-loop (`per-vu-iterations`).** Each VU waits for a response before issuing its next request, so under a GC pause or saturation the offered load drops instead of queuing (the "coordinated omission" failure mode). This risks understating P95/P99 at the highest-concurrency cells. Per-rep GC-log correlation and CoV-based reproducibility give partial protection. `run-target-openloop.js` provides a targeted validity check at VUS 32/64.
- **Every inference call is a single row in, single prediction out.** There is no batching path anywhere in `fraud-ml-service`. Results characterize unbatched synchronous-call overhead only.
- **Concurrency-scan P99s aren't uniformly powered.** `ITERATIONS_PER_VU` holds per-VU sample count constant while total N grows with VUS (100 at VUS=1, 6400 at VUS=64). P99 confidence intervals widen at lower concurrency levels.
- **OOM kills are checked per cell** and abort the suite immediately, same as a cpu-pin mismatch.
- **GC pause overhead is measured rather than eliminated.** `table_gc_overhead` reports per-rep GC pause time as a percentage of wall-clock time. Treat a rep above roughly 1%, or with a single pause near the P99 latency, as a candidate confound for that rep's tail.
- **Instrumentation overhead is measured rather than removed.** The `calibration` target bounds it as a floor.
- **No verification the three `cpuset` ranges are on distinct physical cores** rather than SMT siblings.
- **Pinning assumes a native Linux Docker host.** On Docker Desktop (macOS/Windows), `cpuset` inside the VM has no fixed relationship to physical cores.
- **On WSL2/Docker Desktop specifically, `verify_cpu_pinning()` can pass while pinning still isn't real.** cgroup-level `cpuset` is honored inside the WSL2 VM, so the requested-vs-live cgroup check reports OK. The Hyper-V host scheduler can still migrate the underlying virtual CPUs across physical cores, though, and this script has no way to observe or catch it. `run-suite.sh` detects WSL2 and records `wsl2_detected` in `run_metadata.json` so any affected `results/` snapshot stays traceable. Treat concurrency-scan tail-latency claims (E2) as more exposed to this than the baseline decomposition (E1), since scheduling pressure scales with load.
- **Ablation runs at 1 rep by default (`REPS_ABLATION=1`).** CIs and the control-vs-extreme significance test require at least 2 reps. Set `REPS_ABLATION_OVERRIDE=5` for publishable ablation results.
- **Ablation arms `thread_limiter` and `cpuset` fix `UVICORN_WORKERS=1`.** Their absolute Thread Dispatch numbers won't match figure5 (recorded at workers=3); only the workers=3 cell in the workers arm is directly comparable to the main suite.
- **CPU governor and frequency are captured as a single per-suite snapshot.** Won't catch mid-run thermal throttling.
- **Synthetic, uniformly-random feature vectors.** The licensed dataset can't be bundled, so `randomFeatures()` draws in a rough PCA-shaped range instead.
- **Repetition counts (5 baseline, 5 scan) aren't power-justified.** Each rep is a full clean-slate restart, so the count reflects a wall-clock tradeoff. Five versus five is also the smallest N at which a two-sided Mann-Whitney test can reach significance (p=0.0079 < 0.05).
- **Reduced feature space even at the largest tier.** `V1..V28` plus `Amount` is the full PCA set available, but the source dataset itself is a reduced, anonymized representation.
- **In-memory H2.** Wiped on restart; export `results/` before tearing down.
- **Log files reflect the last run only.** `run_metadata.json`, `run_order_log.txt`, `run_failures_log.txt`, and `cpu_pin_check_log.txt` are truncated fresh each run; prior runs are archived automatically to `results/archive/<timestamp>/`.
- **Mock and calibration are latency baselines only.** Neither performs a real fraud check.
- **`--synthetic` training data is a smoke test only**, not a source for benchmark-grade models.
- **`n_jobs=1` verification** confirms the sklearn/XGBoost-level parameter reads back correctly. Combined with the BLAS env vars, it gives strong assurance of single-threading.
- **8-core pinning is host-specific.** Results aren't comparable across different core counts or SMT settings without adjusting `cpuset`.

---

## Structure

```
.
├── docker-compose.yml
├── analysis/
│   ├── analyze-results.py        # main suite tables, figures, significance tests
│   ├── analyze-ablation.py       # ablation decomposition tables, figures, significance test
│   └── requirements.txt
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── run-smoke-test.sh         # reduced-scale pipeline check before the full suite
│   ├── run-ablation.sh           # thread-dispatch mechanism sweep (post-suite)
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner (closed-loop)
│   ├── run-target-openloop.js    # manual constant-arrival-rate check, top concurrency cells only
│   └── lib/common.js             # shared sendTransaction()/TARGETS + telemetry Trends
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR, THREAD_LIMITER_TOKENS
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py, calibration.py
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/main/java/.../{controller,service,model,repository,dto,exception,filter}/
```

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock/calibration routing, load testing, and telemetry/concurrency work by [MuhammadHussain06](https://github.com/MuhammadHussain06), integrating and extending both.
