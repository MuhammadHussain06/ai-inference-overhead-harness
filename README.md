# AI Inference Overhead Harness

A containerized testbed that measures the **latency and throughput cost of a live AI fraud-inference call**, benchmarked against a network-equivalent mock and a zero-work calibration floor.

```bash
./setup.sh                                   # once per machine
docker compose up                            # bring up the stack
./load-testing/run-suite.sh                  # run the full benchmark suite
analysis/venv/bin/python3 analysis/analyze-results.py   # generate tables + figures
```

---

## Table of Contents

- [Idea](#idea)
- [Scope](#scope)
- [Research questions](#research-questions)
- [Architecture](#architecture)
- [Features](#features)
- [Dataset](#dataset)
- [API](#api)
- [Containerization & Hardware](#containerization--hardware)
- [Running](#running)
- [Outputs](#outputs)
- [Diagnostics](#diagnostics)
- [Tests](#tests)
- [Fault-injection guard verification](#fault-injection-guard-verification)
- [Troubleshooting](#troubleshooting)
- [Experimental design rationale](#experimental-design-rationale)
- [Threats to validity](#threats-to-validity)
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

All three cross the same wire: Java's WebClient calls `fraud-ml-service` over HTTP in every case. Mock and calibration differ only in how little Python does once the request arrives. That separation lets you attribute latency by subtraction:

- **Mock − Calibration** is approximately the cost of one random draw
- **AI tier − Calibration** is approximately DataFrame construction plus model inference
- DB persistence (`APP_DB_SAVE_ENABLED=false`) is off for all benchmark runs, so writes never enter the measured path
- In-memory H2, so every run starts from a clean slate

---

## Scope

**This testbed answers:** in a synchronous, single-node, single-request microservice call, how much of end-to-end latency is model compute versus everything else (network, framework, serialization, queueing), and how that ratio shifts with model complexity (feature-tier) and concurrency.

**It deliberately does not answer:** batched or dynamic-batching inference cost (every call is a single row in, single prediction out, see [Threats to validity](#threats-to-validity)), multi-model or multi-tenant serving, GPU-backed inference, multi-region or multi-hop network latency, or production fraud-detection accuracy. Accuracy is never measured. The fraud-detection model is an incidental stand-in workload chosen for its four-tier feature-count structure, not for its domain.

---

## Research questions

| | Question | Answered by |
|---|---|---|
| **RQ1** | In a synchronous microservice call, how does end-to-end latency decompose across model inference, DataFrame construction, thread dispatch, framework overhead, and the network hop? | E1 baseline (`run-suite.sh`), tables 1 to 3, figures 1 to 2 |
| **RQ2** | How does that decomposition shift with model complexity (feature-count tier) and with request concurrency? | E1 across tiers plus E2 concurrency scan, tables 4 to 6, figures 3 to 5 |
| **RQ3** | Which system-level mechanism, thread-limiter capacity, available core count, or process count (GIL), drives the thread-dispatch cost that dominates at high concurrency? | Ablation (`run-ablation.sh`), `analyze-ablation.py`. Four arms: the three mechanisms, plus a repeat of the worker sweep with aggregate token capacity held constant, since the limiter is per process and a worker-count change moves both at once |

The three-strategy design is what makes RQ1 answerable by subtraction: `calibration` bounds the
framework and transport floor, `mock` adds the thread-dispatch path without compute, and the AI
tiers add real inference. Each pair differs in exactly one layer, so the difference attributes to
that layer. `test_api.py` asserts the three arms emit structurally identical telemetry, which is
the precondition for that subtraction being valid.

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

- Stage-by-stage latency nested in every response: parsing, network, DB write, response build (Java); parsing, thread dispatch, DataFrame construction, model inference, compute stall, serialization (Python). WebFlux's serialization of the Java response body is not captured on either side.
- Timeouts and connection errors (`status=0`) tracked separately from HTTP errors.
- Client-side connection contention (`http_req_blocked`) reported as its own diagnostic, so a throughput plateau can be checked against the load generator before blaming server capacity.
</details>

<details>
<summary><b>Isolation and verification</b></summary>

- Reactive Java stack end to end (WebFlux + R2DBC).
- CPU pinning verified per repetition against each container's *live* cgroup cpuset, since the requested compose config alone does not confirm what the container actually got.
- Physical-core isolation verified before any container starts: each cpuset is resolved to physical cores via `thread_siblings_list`, and the suite aborts if python, java and k6 turn out to share cores through SMT siblings. Disjoint cpusets do not imply disjoint hardware.
- Model inference pinned to `n_jobs=1`, read back at load *and* re-read after real inference (`nJobsVerified` / `nJobsRuntimeVerified` on `/health`). `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, `NUMEXPR_NUM_THREADS` are pinned to 1 and asserted from `/health` each rep, since `n_jobs` alone does not constrain the BLAS layer beneath it.
- `THREAD_LIMITER_TOKENS` (default `40`) pins anyio's thread-limiter capacity as an explicit experimental parameter rather than leaving it to the library default. It is re-read from `/health` every rep and a mismatch aborts the run.
- Host thermal state is recorded, not inferred. `env_trace_log.txt` carries the CPU governor, per-core frequency, highest thermal-zone temperature and the kernel's per-core thermal-throttle counters at both ends of every rep and of every measured cell, plus every thermal check with the time it paused for (`load-testing/lib/thermal.sh`). The analysis turns that into per-cell temperature and throttling, the wall-clock cost of thermal pauses, and a test of whether either tracks latency.
- Valid feature-tier set is fetched from `fraud-ml-service`'s `/health` at startup, never hardcoded in Java. `run-suite.sh` re-verifies this per rep (`loadedTiers` matches expected, `nJobsVerified` all true) and aborts the suite if it does not.
- JVM thread pins are verified against how the JVM itself resolved them. G1 as the collector and its worker-thread ceilings are read back via `-XX:+PrintFlagsFinal` (`load-testing/lib/jvm-pins.sh`), including each flag's *origin*, distinguishing a value that merely coincides with the pinned one through JVM ergonomics from a value the compose file actually set. The Reactor Netty event-loop count is a system property, invisible to that flag dump, so it is checked instead by a `/proc` thread census counting live GC and event-loop threads against their pinned ceilings. The flag-origin check runs at the start of every rep; the census runs after warm-up, once every event loop has served traffic. Either mismatch aborts the suite, same as a cpu-pin failure.
- Host-level state that can shift measured latency without appearing in this project's own configuration (kernel `isolcpus`, AC vs. battery power, whether `irqbalance` is migrating interrupts across pinned cores) is sampled every rep (`load-testing/lib/host-provenance.sh`) and recorded in `run_metadata.json`. Warn-only by design: none of the three has one correct value for every host, so the harness records what it found rather than dictating a setting. Only conditions that invalidate a measurement outright (cpu-pin, tier, JVM-pin mismatches) abort the run.
- Outbound Java to Python connection pool is sized by the harness at 2x the run's peak VUS (`PYTHON_SERVICE_MAX_CONNECTIONS`), so it can never become the bottleneck being measured, and is logged at startup. A hand-started stack falls back to `128`.
- A thermal guard samples every readable `thermal_zone*` after every cell and warm-up chunk. At or above `THERMAL_WARN_C` (90C) the run pauses for `THERMAL_COOLDOWN_S` (60s) and retries, up to `MAX_THERMAL_COOLDOWNS` (2) times; still at or above `THERMAL_CRIT_C` (95C) after that aborts the suite. Every check is logged with the time it paused for, so a long run's thermal cost is measured rather than absorbed into the numbers.
- In-memory H2, clean slate every run.
- Per-request logging is off on both services (Java: `TransactionService` at `WARN`; Python: `uvicorn --no-access-log`). A synchronous stdout write on the WebFlux event loop or the request coroutine would otherwise stall it, adding latency and throughput noise unrelated to inference.
- JVM GC events are logged to `results/gc-logs/gc_<phase>_rep<N>.log`, one file per rep. The rep's pin-check probe JVMs share the container's `JAVA_TOOL_OPTIONS`, so the last of them reopens `gc.log` before warm-up; each archived log therefore spans that rep from its verification to the service JVM's exit, and the GC table measures that window by the records' wall-clock timestamps. This lets tail-latency spikes be cross-checked against GC pauses. Unified JVM logging has negligible overhead and does not sit on the request path.
</details>

<details>
<summary><b>Orchestration and analysis</b></summary>

- `run-suite.sh`: full baseline plus concurrency-scan suite across clean-slate restarts, with per-repetition target and concurrency shuffling, CPU-pin verification, host and toolchain provenance fingerprinting, and a failures log. Any condition that invalidates a rep (k6 itself failing, an OOM kill, a pinning, tier or JVM-pin mismatch, a readiness timeout, a host still critically hot after its cooldowns) aborts the suite rather than being logged and skipped, and `analyze-results.py` rejects the whole dataset if that log has any entries. Request-level errors inside a cell (non-200 responses, timeouts) do not abort: they are counted per cell in the error tables, and every latency table covers HTTP 200 requests only.
- `warm-up.js`: JIT and pool warm-up, hitting every target sequentially in its own window. `converge_warmup()` re-runs it in 15s chunks (`WARMUP_CHUNK_DURATION_S`) up to `MAX_WARMUP_CHUNKS` (4) times per restart, stopping as soon as every target's tail has settled (see [Experimental design rationale](#experimental-design-rationale)). Warm-up shares code with `run-target.js`, so warm-up traffic is tagged and classified identically to measured traffic.
- `calibrate_scan_targets()`: once, before the scan reps, a stack prepared exactly like a scan rep (restart, pin checks, both warm-up passes) runs a measured pre-pass per target at `CALIB_VUS=16`, and `ITERATIONS_PER_VU` for each of `CALIB_AFFECTED_LEVELS` (8, 16, 32, 64) is derived from it so every cell spans about `CALIB_TARGET_DURATION_S` (60s) of wall clock. Every scan rep then runs those counts. Throughput differs by a large factor between targets, so a flat iteration count would make a trivial target's cell span seconds and an AI tier's span minutes. The pre-pass writes `calib_*.json.gz`, which the analysis ignores, and `calibration_log.txt`.
- `analyze-results.py`: P50/P95/P99 tables and histograms per strategy and tier, Mann-Whitney U significance testing (Holm-Bonferroni corrected, rank-biserial effect sizes), cluster-level bootstrap CIs, reproducibility (CoV% across reps), paired error and timeout tables, client-contention diagnostics, warm-up convergence checks, within-cell drift, per-cell thermal state and throttling, throughput-vs-concurrency figures, and an optional open-loop-vs-closed-loop validity check (see [Running](#running)) when `openloop_*.json` files are present. Throughput is measured within each repetition and then averaged; a span pooled across repetitions would include the restarts and cooldowns between them.
</details>

---

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud), anonymized European transactions, September 2013.

- Each tier uses the first `n` of 28 `V` PCA components (`V1..Vn`) plus `Amount` (`log1p`-transformed). `V10` is a strict superset of `V5`, and so on.
- Highly imbalanced (about 0.17% fraud); trained with SMOTE oversampling, then `XGBClassifier`, independently per tier.
- Pretrained models for all four tiers are committed under `services/fraud-ml-service/models/`, so `docker compose up` works with no training step.
- `creditcard.csv` is not bundled (Kaggle license). To retrain: place it at `services/fraud-ml-service/training/data/creditcard.csv`, or pass `--synthetic` for a structural smoke test only.

```bash
# train one tier
training/train_model.py --n-features {5,10,20,28}

# omit the flag to train all four → models/fraud_model_v{n}.joblib
```

The Python service loads whichever tiers are listed in `FEATURE_TIERS` (default `5,10,20,28`) and refuses to start if a listed tier's `.joblib` is missing.

---

## API

### Request

Clients always send the full `V1..V28` vector, regardless of tier. Each endpoint slices what it needs, so one request body works against any tier. Mock and calibration ignore `features` entirely.

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

- `featureTier` selects the model; **required** for `DISTRIBUTED_AI_SYNCHRONOUS`, ignored by mock and calibration. The accepted set is whatever `fraud-ml-service` reports at `/health`, not a hardcoded list.
- `features` must contain at least `featureTier` values.
- `transactionId` must be a UUID; `accountId` must match `ACC-\d{4,10}`. Both are validated before reaching the AI layer. Invalid requests get a `400` with per-field errors.

### Response

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "accountId": "ACC-12345",
  "amount": 12500.50,
  "transactionType": "WIRE_TRANSFER",
  "riskScore": 0.9123,
  "transactionStatus": "FLAGGED",
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10,
  "executionTimeMs": 14.7,
  "requestPreprocessingTimeMs": 0.03,
  "aiCallRoundTripTimeMs": 8.9,
  "estimatedBridgeOverheadMs": 6.59,
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
| `requestPreprocessingTimeMs` | From the `RequestTimingWebFilter` stamp (taken before WebFlux dispatch) to the start of the AI call: WebFlux dispatch, request body decode, bean validation (`@Valid`), and this service's own strategy/feature-tier cross-field checks. Despite the name, none of that is pure deserialization, hence "preprocessing" rather than "parsing" |
| `aiCallRoundTripTimeMs` | Java-side timing of the call to `fraud-ml-service`, from just before the outbound request is sent to just after the response is received. Timed inside a `Mono.defer`, so the clock starts at actual subscription rather than at Mono assembly; without that, the gap between building the call and WebFlux actually subscribing to it (handler return, the downstream `.map`, WebFlux's own result-handler dispatch) would be charged here as network time instead of framework overhead |
| `estimatedBridgeOverheadMs` | `aiCallRoundTripTimeMs` minus Python's `totalPythonExecutionTimeMs`: Docker bridge-network transit, FastAPI routing, queuing, outbound-pool wait. Not a real network hop, see [Threats to validity](#threats-to-validity) |
| `dbWriteTimeMs` | `0.0` when `APP_DB_SAVE_ENABLED=false` (required for benchmarks) |
| `responseObjectBuildTimeMs` | Time to assemble the final `ResponseDto` |
| `executionTimeMs` | Full Java-side duration, timestamped from the WebFlux filter chain (`RequestTimingWebFilter`), so it includes Netty and WebFlux routing |

**Python-side fields (`pythonTelemetry`)**

| Field | Meaning |
|---|---|
| `parsingRequestTimeMs` | Request parsing and validation |
| `threadDispatchTimeMs` | Thread-pool queueing before the handler runs (measured for all three strategies) |
| `computationTimeMs` | The whole worker-thread window: validation, the `log1p` transform, row build, DataFrame construction, inference, and threshold comparison. A superset of `dataframeConstructionTimeMs` plus `modelInferenceTimeMs`, and `0.0` for mock and calibration |
| `dataframeConstructionTimeMs` | The `pd.DataFrame()` call only. XGBoost's later ingestion of that frame is counted in `modelInferenceTimeMs` |
| `modelInferenceTimeMs` | The complete `predict_proba` call: feature-name validation, conversion of the pandas DataFrame into XGBoost's internal `DMatrix`, and booster tree traversal. See [Threats to validity](#threats-to-validity) for what dominates it |
| `computeStallMs` | Portion of compute time the thread was off-CPU (GIL or OS scheduling) |
| `serializationResponseTimeMs` | Estimated response-serialization cost |
| `totalPythonExecutionTimeMs` | Total self-reported Python execution time |

> `serializationResponseTimeMs` and `totalPythonExecutionTimeMs` are estimates. A response cannot report the cost of serializing itself without a prior serialization pass.

---

## Containerization & Hardware

| | python-service | transaction-service | k6 (load generator) |
|---|---|---|---|
| Image | `python:3.11-slim` | build `eclipse-temurin:21-jdk-alpine`, run `21-jre-alpine` | `grafana/k6:0.54.0` (pinned) |
| Port | `8000` | `8080` | n/a |
| Cores (`cpuset`) | `0-1,4-5,8-9` (physical 0, 2, 4) | `2-3,6-7` (physical 1, 3) | `10-11,14-15` (physical 5, 7) |
| Limit / reserved | 6.0 CPU / 3G RAM (1G reserved) | 4.0 CPU / 3G RAM (1G reserved) | 4.0 CPU / 1G RAM |
| Notes | `UVICORN_WORKERS=3` and `THREAD_LIMITER_TOKENS=40` at benchmark time; `n_jobs=1` plus BLAS env vars keep each `predict_proba` call single-threaded, independent from the 3-worker concurrency | Outbound pool to Python sized via `python.service.max-connections` (default `128`); must stay at or above the highest VUS in `run-suite.sh`'s `CONCURRENCY_LEVELS` (currently `64`) or queueing inflates `estimatedBridgeOverheadMs`. `python.service.pending-acquire-timeout-ms` (default `5000`) bounds the wait. Feature-tier set fetched from Python's `/health` at startup, retrying up to 60s. Heap fixed via `JAVA_TOOL_OPTIONS=-Xms1536m -Xmx1536m` for reproducible sizing across hosts and reps | Runs in its own container on a disjoint cpuset. Gated behind the `loadgen` Compose profile; invoked per-cell by `run-suite.sh` via `docker compose run`, not started by `docker compose up` |

The k6 image tag is pinned rather than floating, because it is the only image not built from this tree. `run_metadata.json` records the resolved digest for each run.

Resource limits (`mem_limit`/`mem_reservation`/`cpus`) use Compose's plain (non-Swarm) top-level keys rather than `deploy.resources.limits`, which is a Swarm-only directive silently unenforced by `docker compose up`.

**Requirements**

- Docker + Docker Compose v2 (`docker compose`)
- 16 logical cores. The `cpuset` values span CPUs 0 to 15 and are chosen for a host whose SMT siblings are *adjacent* logical CPUs, so each service owns whole physical cores. On a host that enumerates siblings differently (Intel's classic `N` / `N+8` layout, for instance), `verify_smt_isolation()` resolves each cpuset through `thread_siblings_list` and aborts before any container starts, avoiding incomparable data.
- Re-pick the values for your topology with `cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list`, or let `load-testing/recommend-cpusets.sh` do it: it reads this host's topology, restricts itself to performance cores on a hybrid CPU, and prints `export` lines for `PYTHON_CPUSET`/`JAVA_CPUSET`/`K6_CPUSET` (plus the ablation's narrow and wide cpuset values), pre-checked against the same guard the suite runs. It only recommends: review the output, `export` it, then run the suite.
- About 7GB free RAM
- k6 runs containerized for `run-suite.sh` and `run-ablation.sh`, pulled automatically on first invocation, so no host install is needed for either. A host-installed `k6` binary is only needed for the manual and open-loop commands below
- Python 3 on the host, required by `run-suite.sh` itself (tier verification) in addition to `pip install -r analysis/requirements.txt` (pandas, numpy, matplotlib, scipy, statsmodels, tabulate, jinja2) for the analysis phase. `jinja2` backs the LaTeX table export, so omitting it breaks `.tex` output. `requirements.txt` pins floors, not ceilings: recent CPython (3.13+) needs recent-enough wheels of these anyway, and older exact pins can fail a from-source build on a newer compiler toolchain
- No GPU required

---

## Running

### First-time setup (once per machine)

```bash
./setup.sh
```

Neither service's Dockerfile sets a non-root `USER`, and the upstream `k6` image runs as its own fixed non-root UID. Without this step, `docker compose up` auto-creates `results/` and `results/gc-logs/` owned by root (or by a UID that is not yours), and later writes into them from the `k6` container fail outright. `setup.sh` writes a `.env` with your UID and GID (which `docker-compose.yml` picks up via `user: ${HOST_UID:-1000}:${HOST_GID:-1000}` on all three services), pre-creates `results/gc-logs/` so it is host-owned from the start, and creates `analysis/venv/` with `analysis/requirements.txt` installed into it (Ubuntu 24.04+ refuses a bare `pip install` against the system Python). Safe to re-run.

### Smoke test (recommended before the full suite)

A small, fast pass through the same verified pipeline (2 targets, 2 concurrency levels, 2 reps, reduced iteration counts) to catch a structural problem such as a bad config, a broken tag or a mislabeled tier in minutes instead of hours into a real run. It also fires a deliberately unsustainable 20s open-loop cell at `RATE=5000` to confirm `dropped_iterations` is actually detected, runs a two-cell slice of the ablation (the `cpuset` arm, whose values are cpuset strings rather than integers), and runs **both** analysis scripts. Every path the full suite depends on is exercised.

```bash
docker compose up -d
cd load-testing
./run-smoke-test.sh
```

Check `run_failures_log.txt` and `cpu_pin_check_log.txt` afterward, and confirm the `[+] smoke-openloop:` line the script prints reports a nonzero `dropped_iterations` count. Table 7 will *not* show that cell: `analyze-results.py` excludes `phase=smoke-openloop` on purpose, and the script checks the raw file directly instead. Clean here means the pipeline is trustworthy, not that any given rep count is sufficient. Re-run the smoke test after any fix until it passes, then move to the full suite.

Table 0 is also expected to list every target as `fewer than three windows` on a smoke run: its convergence check needs three windows of at least 500 requests each, and the smoke slice sends about 20 per target.

`run-suite.sh`'s `TARGETS`, `CONCURRENCY_LEVELS`, `REPS_BASELINE`, `REPS_SCAN`, `BASELINE_ITERATIONS`, and `SCAN_ITERATIONS_PER_VU` are all overridable via `TARGETS_OVERRIDE`, `CONCURRENCY_OVERRIDE`, `REPS_BASELINE_OVERRIDE`, `REPS_SCAN_OVERRIDE`, `BASELINE_ITERATIONS_OVERRIDE`, and `SCAN_ITERATIONS_PER_VU_OVERRIDE`. `run-ablation.sh` takes `ABLATION_CELLS_OVERRIDE`, `REPS_ABLATION_OVERRIDE`, `ABLATION_VUS_OVERRIDE`, `ABLATION_TARGET_OVERRIDE`, `ABLATION_CALIB_ITER_PER_VU_OVERRIDE` and `ABLATION_CALIB_TARGET_DURATION_S_OVERRIDE` (`ABLATION_ITERATIONS_PER_VU_OVERRIDE` also exists but only sets a metadata fallback; the measured cell's actual count always comes from calibration, so the two `ABLATION_CALIB_*_OVERRIDE` variables are what actually shrink an ablation slice). `run-smoke-test.sh` is a thin wrapper setting both to a small slice; unset, each script runs its full default design.

### Full suite

Restarts the stack per repetition, shuffles order, logs provenance.

```bash
./setup.sh          # once per machine, see "First-time setup" above
docker compose build
cd load-testing
./run-suite.sh                                       # baseline + concurrency scan, all reps
../analysis/venv/bin/python3 ../analysis/analyze-results.py   # tables + figures
```

Requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`.

Per repetition, `run-suite.sh` restarts the stack, runs the convergence-gated warm-up, then drives `run-target.js` per target and concurrency cell across `mock`, `calibration`, and the four AI tiers. A second max-VUS warm-up pass runs before each scan rep's cells, and every target is throughput-calibrated once, in its own pass before the scan reps. Defaults: 7 baseline reps, 7 scan reps, concurrency levels 1/2/4/8/16/32/64, 10s cooldown between cells.

### Ablation (RQ3)

The mechanism sweep is a separate script and is not run by `run-suite.sh`.

```bash
cd load-testing
./run-ablation.sh                                              # 11 cells x 7 reps
../analysis/venv/bin/python3 ../analysis/analyze-ablation.py   # ablation tables + figure
```

It holds the workload fixed at `TARGET=28`, `VUS=64` and sweeps one mechanism at a time across 11 cells in four arms: `thread_limiter` (40/64/128 tokens), `cpuset` (narrow/control/wide), `workers` (1/2/3 uvicorn processes), and `workers_token_matched` (1 worker at 40 tokens vs. 3 workers at 13 tokens each, aggregate capacity matched to the nearest integer since the limiter is per process and a worker change otherwise moves both variables at once). Each cell is throughput-calibrated once, in a pass before the reps that restarts the stack at that cell's configuration and warms it up exactly as its reps will, and every rep of the cell runs that count. Every cell gets the same warm-up convergence gate, cpu-pin and JVM-pin verification, thermal telemetry and abort-on-invalid behavior as the main suite.

`table_ablation_control_vs_extreme` makes one planned comparison per arm: its control value, as `run-ablation.sh` recorded it in `ablation_run_metadata.json`, against the sweep value farthest from it by value (logical CPUs for a cpuset). That is the arm's largest manipulation whether the control sits at an end of the sweep (`thread_limiter` 40, `workers` 3) or inside it (`cpuset`, where the 2-CPU cell is farther from the 6-CPU control than the 8-CPU one). `workers_token_matched` has no control (its two values are a matched pair at fixed aggregate token capacity) and compares its two values directly.

### Manual or one-off run

```bash
docker compose up                                    # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
k6 run --out json=results/results.json your-test.js  # real load test
analysis/venv/bin/python3 analysis/analyze-results.py   # tables + figures
```

These commands invoke `k6` directly rather than through Docker, so they need a host-installed `k6` binary; `run-suite.sh` and `run-ablation.sh` run it in its own container instead and need no such install.

`warm-up.js` reads `WARMUP_TARGETS` (default `mock calibration 5 10 20 28`), `WARMUP_VUS` (5), and `BASE_URL` (falls back to `http://localhost:8080/api/v1/transactions`). By default it uses a `constant-vus` executor bounded by `WARMUP_DURATION_S` (15). Setting `WARMUP_ITERATIONS_PER_TARGET` switches it to a fixed-count `per-vu-iterations` pass bounded by `WARMUP_MAX_DURATION_S` (60) instead, which is the path the smoke test takes; that variable also bypasses `converge_warmup()`'s chunked gate entirely, so do not set it when you want the adaptive warm-up.

### Open-loop validity check (optional)

The main suite's concurrency scan is closed-loop (see [Threats to validity](#threats-to-validity)). `run-target-openloop.js` runs the same target under a `constant-arrival-rate` executor instead, so requests fire on a fixed schedule regardless of how fast responses come back. This is the standard mitigation for coordinated omission. Run it against the top one or two concurrency cells only, after the main suite, as a check on whether the closed-loop tail-latency numbers hold up:

```bash
docker compose up
k6 run load-testing/warm-up.js
TARGET=28 RATE=32 TIME_UNIT=1s DURATION=2m PRE_ALLOCATED_VUS=64 MAX_VUS=128 \
  k6 run --out json=results/openloop_28_rate32.json load-testing/run-target-openloop.js
```

`RATE` is requests per `TIME_UNIT`. Set it to roughly the throughput the closed-loop cell achieved at that VUS level, not the VUS count itself. `PRE_ALLOCATED_VUS` and `MAX_VUS` must be generous enough to sustain `RATE` if response times climb. k6 emits `dropped_iterations` when it cannot keep up, which is itself diagnostic: it means the server cannot sustain that arrival rate, a real finding rather than a script bug. This script is standalone and manual by design. It is not invoked by `run-suite.sh` and does not replace the main suite.

Output filenames must start with `openloop` (for example `openloop_28_rate32.json`). `analyze-results.py` detects any such files in `--results-dir`, and if present adds `table7_openloop_validity_check` and `figure7_openloop_validity_check` comparing open-loop P95/P99 against the closed-loop scan at the top two scanned concurrency levels for the same tier. If no `openloop_*` files are present, this step is skipped silently and the rest of the analysis is unaffected. `run-smoke-test.sh`'s own `RATE=5000` overload cell (`phase=smoke-openloop`) is always excluded from this table, whether or not its file happens to still be sitting in `results/`. Table 7 is grouped by tier *and* `RATE`, so a real check at a sane rate is never pooled with a leftover overload cell from a different one.

---

## Outputs

`run-suite.sh` writes into `results/`:

| File | Contents |
|---|---|
| `baseline_<target>_rep<N>.json.gz` | One file per baseline cell |
| `scan_<target>_vus<V>_rep<N>.json.gz` | One file per (target, concurrency, rep) scan cell |
| `warmup_baseline_rep<N>.json.gz`, `warmup_scan_rep<N>.json.gz`, `warmup_scan_maxvus_rep<N>.json.gz` | Warm-up latency, tagged `phase=warmup`, for the convergence check |
| `calib_<target>_vus16.json.gz`, `calib_warmup_scan*.json.gz` | The calibration pass's measurement per target and its warm-up; not read by the analysis |
| `calibration_log.txt` | The iteration counts per concurrency level that every scan rep ran each target with |
| `run_order_log.txt` | Shuffle order per repetition |
| `run_metadata.json` | Timestamp, Docker/Compose versions and k6 image digest, git commit and dirty flag, CPU/RAM, CPU governor and frequency snapshot, host provenance (`isolcpus` live state and boot cmdline, AC/battery power source, `irqbalance` status) |
| `cpu_pin_check_log.txt` | Per-repetition requested-vs-live cpuset, including the `smt_check` lines |
| `env_trace_log.txt` | `env_sample` lines at both ends of every rep (governor, per-core frequency, temperature, throttle counters); `cell_start`/`cell_end` lines around every measured cell (temperature and the package and per-core thermal-throttle counters, `na` where the host does not expose them); and a `thermal_check` line for every safety check with the time it paused. Per-core values are `cpuN=value` pairs in core-index order, so each is attributable to a specific core |
| `run_failures_log.txt` | Empty on a valid run; any entry makes `analyze-results.py` reject the dataset |
| `gc-logs/gc_<phase>_rep<N>.log` | JVM GC events for that rep, from its last pin-check probe to the service JVM's exit |

`run-ablation.sh` writes the same shapes under `ablation_` prefixes: `ablation_<arm>_<value>_rep<N>.json.gz` plus `ablation_warmup_*`, `ablation_calib_*` (the calibration pass's measurement and warm-up per cell), `ablation_calibration_log.txt`, `ablation_run_order_log.txt`, `ablation_run_metadata.json` (including the control value of each arm), `ablation_cpu_pin_check_log.txt`, `ablation_env_trace_log.txt`, and `ablation_run_failures_log.txt`.

k6 writes its full unfiltered trail to `results/raw/` first; `finalize_result()` keeps only the metrics the analysis reads (`KEEP_METRICS`, which includes `request_http_error` and `request_timeout_error` so `crosscheck_error_counters()`'s independent error-count check has data to run against, and `java_execution_time_ms` so the Java-side total stays recoverable), gzips the result into `results/`, and deletes the raw copy, so the stored file is a filtered subset of k6's output rather than the raw stream. The filter (`lib/k6_filter.py`) reads each line's metric name from k6's fixed JSON prefix and falls back to a full parse for any line not in that shape. And at the start of a run, the previous run's JSON and logs are moved into `results/archive/<timestamp>/` rather than deleted, so only the top level is cleared.

Analysis output lands in `analysis/output/tables/` and `analysis/output/figures/`, each table as `.csv`, `.md` and `.tex`:

| | |
|---|---|
| Main suite | `table0_warmup_convergence_check`, `table1_baseline_e2e_latency_pooled`, `table1b_baseline_between_run_consistency`, `table1c_baseline_error_rates`, `table1d_baseline_client_diagnostics`, `table1e_measurement_floor_violations`, `table2_baseline_python_decomposition_mean_ms`, `table3_dataframe_share_of_computation`, `table4_concurrency_scan_summary_pooled`, `table4b_scan_between_run_consistency`, `table4c_scan_error_rates`, `table4d_scan_client_diagnostics`, `table4e_scan_within_cell_drift`, `table5_baseline_adjacent_tier_significance`, `table6_scan_adjacent_concurrency_significance`, `table_gc_overhead`, `table8a_thermal_by_group`, `table8b_thermal_pauses`, `table8c_thermal_latency_association`, and `table7_openloop_validity_check` when open-loop files are present |
| Figures | `figure1_baseline_decomposition_stacked_bar`, `figure2_baseline_latency_distribution`, `figure3_p95_latency_vs_concurrency`, `figure4_throughput_vs_concurrency`, `figure5_decomposition_vs_concurrency_v<tier>`, `figure6_between_run_reproducibility_baseline`, `fig_gc_overhead`, `figure8_thermal_timeline`, and `figure7_openloop_validity_check` when applicable |
| Ablation | `table0_ablation_warmup_convergence_check`, `table_ablation_error_rates`, `table_ablation_decomposition`, `table_ablation_control_agreement`, `table_ablation_control_vs_extreme`, `table_ablation_thermal_by_cell`, `table_ablation_thermal_pauses`, `table_ablation_thermal_association`, `figure_ablation_mechanisms`, `figure_ablation_thermal_timeline` |

The tables added to make the run's own conditions visible, and how to read them:

| Table | Reads as |
|---|---|
| `table0*` | One row per warm-up pass and target, including targets that never reached three windows or never returned HTTP 200, with the gate's own status. A `no` means that target entered its measured phase still moving |
| `table4e_scan_within_cell_drift` | Mean change from the first to the second half of each scan cell, with a t-interval across reps. A change of the same sign in every rep means the cell mean depends on the cell's duration, which calibration holds near 60s at VUS 8 and above |
| `table8a_thermal_by_group`, `table_ablation_thermal_by_cell` | Temperature at both edges of each cell and whether any service's cores were throttled during it, per design group. `not exposed` means the host publishes no throttle counters, so throttling is unmeasured rather than absent |
| `table8b_thermal_pauses`, `table_ablation_thermal_pauses` | How often each phase paused for heat, and the wall-clock minutes it cost |
| `table8c_thermal_latency_association`, `table_ablation_thermal_association` | Spearman correlation between a cell's temperature or throttling and its latency, taken as the deviation from its own design cell's mean across reps so the manipulated factor cannot register as heat. A near-zero correlation means thermal state does not explain the between-rep spread |
| `table_ablation_error_rates` | Every ablation request's outcome and the iterations k6 dropped, counted before sampling, since the ablation's latency tables cover HTTP 200s only |

### CPU pinning verification

`cpuset` in `docker-compose.yml` states what pinning was *requested*; it does not guarantee the cgroup driver honored it. Each repetition, `run-suite.sh` compares:

- **Requested**: `docker inspect --format '{{.HostConfig.CpusetCpus}}'`
- **Live**: `docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective` (cgroup v2, falling back to the v1 path)

A mismatch aborts the whole suite immediately (`abort_suite`). No results are written for that rep, and prior reps already on disk are unaffected. A live cpuset the cgroup does not expose is logged as `WARN_SKIPPED` rather than treated as a mismatch; `analyze-results.py` reports how many checks were skipped that way.

`run-suite.sh` also verifies python-service's feature-tier loading each rep via its own `/health` endpoint: the reported `loadedTiers` must match `5,10,20,28` (python-service loads every `FEATURE_TIERS` entry from `docker-compose.yml` on every start, regardless of which subset of targets this run exercises), `nJobsVerified` must be true for every tier, and the thread-limiter token count must match the pinned value. A silent tier-load failure would otherwise corrupt AI-tier cells without ever showing up as a request-level error. Same abort behavior as a cpu-pin mismatch.

A cell whose k6 run fails, or whose containers were OOM-killed, aborts the suite the same way rather than logging it and continuing; `analyze-results.py` rejects the whole dataset if `run_failures_log.txt` has any entries, so there is no benefit to continuing past the first one. Request-level errors inside a cell that ran (non-200 responses, timeouts) are not a failure of the cell: tables 1c and 4c report them per cell, and the latency tables are computed on HTTP 200s only.

---

## Diagnostics

`load-testing/probing/` holds six standalone diagnostics, none wired into `run-suite.sh` or `run-ablation.sh`. They exist to re-derive the harness's tuning constants on a new host, which is what a reproducer needs to justify those constants rather than inherit them. `probe_warmup_joint.sh` and `probe_warmup_settle.sh` write their intermediates to `results/probes/` and clean up after themselves; `probe_ablation_taper.sh` and `calibrate_scan_iterations.sh` write straight into the main `results/` tree and leave their output there, so running either one leaves a `probe_ablation_*`/`calib_*` file behind. Each resolves the compose file at `../../docker-compose.yml`, so run them from inside `load-testing/probing/`.

| Script | Question it answers |
|---|---|
| `probe_warmup_joint.sh LABEL VUS [...]` | Does the real gate condition, every target converging in the same chunk, actually become reachable, and which target is the laggard when it does not? Runs past `MAX_WARMUP_CHUNKS` and prints every target's verdict at every checkpoint from `lib/warmup_gate.py` itself, at the production window, minimum span, tolerance and floor unless overridden |
| `probe_warmup_settle.sh LABEL TIER VUS [...]` | Where does a single non-converging target actually settle? Same chunks, one target, past the cap, with a thermal check after each. `WARMUP_WINDOW_OVERRIDE` / `WARMUP_MIN_SPAN_OVERRIDE` / `WARMUP_TOL_OVERRIDE` / `WARMUP_ABS_FLOOR_OVERRIDE` change the criterion to test how a target's verdict depends on the window and bounds at its own per-request variance |
| `calibrate_scan_iterations.sh TIER [REF_VUS] [TARGET_DURATION_S] [CALIB_ITER_PER_VU]` | What `ITERATIONS_PER_VU` does each concurrency level need on this host to hit a target cell duration? The same derivation `calibrate_target()` runs, in a form you can inspect |
| `probe_calibration_drift.sh TIER [N_MEASUREMENTS] [REFERENCE_VUS] [ITER_PER_VU] [COOLDOWN_S]` | Does a target's calibrated throughput actually hold constant across reps, the assumption the once-per-target calibration pass depends on? Repeats `calibrate_target()`'s own measurement back to back and reports the spread |
| `probe_ablation_taper.sh LABEL CPUSET CPUS WORKERS TOKENS [TARGET_DURATION_S]` | Does a given ablation arm's real processing capacity change what cell duration it needs? Checked per arm, because each arm changes python-service's throughput by design |
| `probe_telemetry_completeness.sh [N_REQUESTS] [TARGET...]` | Is every telemetry field actually present on a live response, for every target? Checks build freshness against source mtimes first, then all eight `python_*` and two `java_*` fields per response |

`analysis/probing/plot_warmup_curve.py` is a seventh diagnostic, for thermal investigation rather than warm-up tuning. It overlays rolling P50 latency against active VUs, package temperature and core frequency within a single result file (`.json` or `.json.gz`), so a throttle signature can be read against the load rather than inferred from temperature alone. It takes `--thermal-log` (a `sensors` poll) and/or `--turbostat-log`, and resolves `--results-dir` relative to its own location, so it runs from any directory. The active-VU line needs the `vus` metric, which the harness filters out of finalized files. `calibrate_scan_iterations.sh` writes with a bare `--out json=` rather than through the harness's filter, so its raw file is the one that still has it.

---

## Tests

The measurement instruments are unit-tested, since every reported figure depends on them
being correct. None of these suites run during the Docker build, so the images stay free of
test tooling and the measured containers stay identical to what is shipped.

`./install-test-deps.sh` (run once from the repo root) sets up everything below in one pass:
`analysis/venv` plus its `requirements-dev.txt`, `services/fraud-ml-service/.venv` plus its
own `requirements-dev.txt`, and `bats-core` for the shell test suite. It is distinct from
`setup.sh`, which only prepares what is needed to run the measurement stack for real numbers.
Maven fetches its own test dependencies (JUnit, `spring-boot-starter-test`, `reactor-test`)
automatically on first `./mvnw test`, so there is nothing to pre-install there.

```bash
./install-test-deps.sh   # once, sets up every test toolchain below

# Python service (50 tests): timing invariants, EWMA convergence,
# n_jobs pinning, telemetry symmetry across the three strategies,
# server-fault vs. client-input error classification
cd services/fraud-ml-service
.venv/bin/python3 -m pytest tests/ -q

# Analysis pipeline and the harness's Python libraries (115 tests): cell-value
# parsing, throughput measurement, cluster bootstrap, effect size, GC log
# parsing, k6 JSON loading, reservoir sampling and its non-200 exemption, true
# request counts, extremes and throughput under subsampling, the warm-up gate
# (lib/warmup_gate.py) and table 0, the k6 result filter (lib/k6_filter.py),
# thermal telemetry and its tables, the ablation's outcome tally and planned
# comparison, low-rep significance floor, open-loop cell identity, and the
# silent-success-on-empty-input guards
cd analysis
venv/bin/python3 -m pytest tests/ -q

# Java service (34 tests): bridge-overhead derivation, netStart captured at
# Mono subscription rather than assembly, telemetry pass-through, strategy
# routing, request-timing filter ordering, ResponseStatusException status
# codes preserved rather than reported as 500
cd services/transaction-service
./mvnw test

# Load-testing harness (90 tests, bats-core): CPU-topology expansion and
# formatting, SMT-sibling and cpuset-quota guards, JVM flag-origin parsing, the
# helpers both harness scripts duplicate, the warm-up convergence gate, the
# throughput calibration and its once-per-run pass, and the thermal guard and
# telemetry
cd load-testing
bats tests/
```

What they guard, and why it matters for the results:

| Test | Protects |
|---|---|
| `test_responses.py` convergence tests | The EWMA serialization estimate stays sub-millisecond and cannot drift, bounding the circularity in `totalPythonExecutionTimeMs` |
| `test_model.py` timing invariants | Compute stall is never negative and never exceeds wall time; computation covers its own components |
| `test_api.py` telemetry symmetry | All three strategies emit identical telemetry fields, the precondition for decomposition by subtraction |
| `test_api.py` baseline-floor tests | `mock` and `calibration` genuinely report zero compute, so they bound inference cost |
| `test_model.py` error-classification tests | A `ValueError` raised inside `predict_proba` itself (a server-side computation fault) reports 500, distinct from the 400 the same exception type gets when it is the explicit too-few-features check |
| `TransactionServiceTest` overhead tests | `estimatedBridgeOverheadMs` is exactly round-trip minus Python total, negative values are preserved rather than hidden, and `netStart` is captured at `Mono` subscription rather than assembly (a real gap between building and subscribing to the call is not charged to `aiCallRoundTripTimeMs`) |
| `GlobalExceptionHandlerTest` | A `ResponseStatusException` (e.g. Spring's own 415 for an unsupported `Content-Type`) reports its own status rather than falling through to the generic 500 handler |
| `RequestTimingWebFilterTest` | The request-start stamp anchoring every Java-side figure is taken at highest filter precedence |
| `test_topology.bats` | Cpuset expansion and formatting, and the SMT-sibling and cpuset-quota guards, behave correctly on synthetic topologies the running host may not have (via `TOPO_SYSFS_ROOT`), the same mechanism the fault-injection suite reuses below |
| `test_jvm_pins.bats` | Flag-origin parsing tells a pinned JVM value from one that merely coincides with it by ergonomics |
| `test_warmup_convergence.bats` | The gate's window spans at least 3s of each target's own traffic, so a sub-second blip is not drift while a sustained shift still is; both bounds behave as documented; one lagging target, or an expected target with no data or no HTTP 200, blocks the chunk; the verdict after the last chunk is the one reported; and `run-ablation.sh`'s copy of the gate is identical to `run-suite.sh`'s |
| `test_calibration.bats` | The per-target iteration derivation scales inversely with concurrency, clamps at one iteration per VU, fails loudly rather than carrying a previous target's counts forward when a calibration yields nothing, and matches `analyze-results.py`'s own `(N-1)/span` throughput convention in both scripts; the calibration pass prepares the stack like a rep, measures each target or cell once, and every rep reads back those counts |
| `test_thermal.bats` | Temperature and throttle counters are read from the hottest zone and in core order, `na` rather than zero where the host exposes nothing; the safety check pauses, logs the pause, and aborts only when still critical after its cooldowns; neither harness script runs against a synthetic sysfs tree |
| `test_harness_libs.py` | `lib/warmup_gate.py` orders Go-trimmed timestamps numerically, sizes the window by time, reports every status, and takes true medians; `lib/k6_filter.py`'s fast path keeps exactly the lines a full JSON parse would |
| `test_analysis.py` table 0 tests | Table 0 judges each warm-up file with the live gate at the run's recorded parameters and keeps a row for every expected target, including ones that never converged, in both analysis scripts |
| `test_analysis.py` reservoir-sampling tests | Non-200 `http_req_duration` points are retained in full regardless of file size, so the error-count cross-check is never degraded by random subsampling; a truncated gzip keeps what decompressed |
| `test_analysis.py` true-count tests | Table 1/4/7's reported N, extremes and throughput reflect every request seen, not the reservoir's sampled subset -- including the cross-metric case where no single metric individually neared the cap but the file's combined point count still did -- and open-loop cells at different rates for the same tier are kept separate rather than summed |
| `test_analysis.py` thermal tests | The parser reads the trace `lib/thermal.sh` actually writes; throttling is attributed per service as its most-throttled CPU; the thermal-latency association is taken within design cells so the manipulated factor cannot read as heat |
| `test_analysis.py` ablation tests | Every request outcome and dropped iteration is counted before sampling, the control value comes from the run's metadata, the planned comparison takes the value farthest from control, and a failed or empty run exits non-zero |
| `test_analysis.py` significance-floor test | `pairwise_mannwhitney` emits a `[!]` when the rep count makes even perfect separation unable to clear alpha, so "Significant: No" at low N is never misread as a null result |
| `test_analysis.py` open-loop cell-identity test | A cell with zero 200 responses (total overload) still gets a table 7 row with its `dropped_iterations` count, instead of vanishing because cell identity was built from 200-only data |
| `test_analysis.py` silent-success guard tests | `crosscheck_error_counters`, `analyze_measurement_floor` and `analyze_gc_logs` each emit a `[!]`/warning on empty or unmeasurable input instead of returning as if the check had passed |

---

## Fault-injection guard verification

The unit tests above check each guard's logic in isolation; this checks that the guards
actually fire against the harness's real abort path. A guard that never fires reports a
clean run identically to a guard that cannot fail.
Each of eight cases misconfigures one pinned setting the suite claims to enforce, runs a
minimal slice of `run-suite.sh` against it, and records whether the expected guard rejected
it. Case `00-unmodified` runs with nothing changed and must instead pass clean, so a version
of the suite where every case aborts is itself reported as a failure, not a pass.

```bash
cd fault-injection
./verify-guards.sh
```

Runs entirely against a generated copy of the compose configuration under
`fault-injection/scratch/`, whose bind mounts and results directory point inside
`fault-injection/`, so nothing under the top-level `results/` is touched. Output goes to
`fault-injection/results/guard_verification_report.{md,csv}`, which is gitignored: like the
main suite's `results/`, it is host- and run-specific regenerable evidence, not something
this repo carries a checked-in copy of.

| Case | Fault | Guard |
|---|---|---|
| `00-unmodified` | Nothing changed | none, must run clean |
| `01-smt-overlap` | python-service on the other hyperthread of each of the Java service's cores: no logical CPU shared, same physical cores | `[smt]` |
| `02-cpuset-splits-core` | python-service takes one hyperthread of each core rather than both | `[cpuset]` |
| `03-cpuset-nonexistent-cpu` | cpuset names a CPU absent on this host | `[smt]` |
| `04-cpu-quota-exceeds-cpuset` | CPU quota larger than the cpuset can supply | `[cpuset]` |
| `05-thread-limiter-drift` | Thread-limiter tokens moved off the pinned baseline | `[tier-check]` |
| `06-feature-tier-drift` | python-service loads an incomplete feature-tier set | `[tier-check]` |
| `07-gc-threads-unpinned` | GC worker-thread count left to JVM ergonomics | `[jvm-pin]` |
| `08-collector-swapped` | Collector swapped from G1 to Parallel | `[jvm-pin]` |

Run `./verify-guards.sh` on the host that will produce the dataset, since the report is
host-specific and not committed. Case 02 and case 01 need an SMT host and are reported as skipped,
not passed, on one without it. One gap is disclosed rather than covered: a configuration whose pinned options are present in the compose file but never
reach the JVM. No compose-level fault reproduces that, so the `[jvm-pin]` guard is only
checked through the flag origin the JVM itself reports, not against that specific failure
mode. Baseline cpusets for cases 01 to 04 are read from `docker-compose.yml`'s defaults if they
still hold on the host running the script, and from `recommend-cpusets.sh` otherwise, so, like
the suite itself, a fault-injection case failing because the *baseline* does not fit this
host is distinguished from one failing because its guard did not fire.

The suite covers config drift: each case changes one compose-level setting and asserts a
named guard rejects it. Measurement-methodology constants such as the warm-up window or
`gracefulStop` are not reachable that way and have no abort path to assert against, so they
are covered by the unit tests above instead.

---

### Troubleshooting

- **`permission denied` writing to `/results/*.json` or `/gc-logs/*` from inside a container.** Means `./setup.sh` was not run, or its `.env` predates a fresh clone. Neither service's Dockerfile sets a non-root `USER`, and `grafana/k6` runs as its own fixed non-root UID either way, so without `HOST_UID`/`HOST_GID` in `.env` the bind-mounted directories end up owned by root or the wrong UID. Run `./setup.sh`, confirm `.env` exists and matches `id -u`/`id -g`, then retry. If `results/` was already created root-owned before `setup.sh` ever ran, `sudo chown -R $(id -u):$(id -g) results/` once to reclaim it.
- **`./setup.sh` or `./run-suite.sh` fails with `Permission denied` before even starting.** The executable bit did not survive however you got the repo onto this machine. A plain `git clone` carries it, but GitHub's "Download ZIP" button does not, and some Windows-side file transfers strip it too. Fix once: `chmod +x setup.sh load-testing/*.sh load-testing/probing/*.sh fault-injection/*.sh`.
- **`Conflict. The container name "/..." is already in use`** on `docker compose up`. Leftover stopped containers from an earlier interrupted run, or from a *different clone or directory* of this same repo, since `container_name` in `docker-compose.yml` is fixed (`python`/`java`) rather than project-scoped, are holding the name. `docker rm -f python java`, then retry.
- **A probe script fails with `open .../load-testing/docker-compose.yml: no such file or directory`.** The probes live one directory below `load-testing/` and resolve the compose file at `../../docker-compose.yml`. Run them from inside `load-testing/probing/`.
- **The suite pauses for a minute mid-run, or aborts with a `[thermal]` message.** The thermal guard found a zone at or above 90C after a cell or warm-up chunk and is cooling down; at or above 95C after two cooldowns it aborts rather than record throttled numbers. On a laptop this is the common cause of a long run stopping on its own. `env_trace_log.txt` has the temperature and throttle counters around every cell and every pause, and table 8b totals the time paused per phase.
- **`error: externally-managed-environment` from `pip install`.** Ubuntu 24.04+ (PEP 668) refuses a bare `pip install` against the system Python. This is what `./setup.sh` exists to avoid: it builds `analysis/venv` and installs `analysis/requirements.txt` into that instead. Use `analysis/venv/bin/python3` or its `pip` for anything analysis-related rather than the bare `python3`/`pip3` on `PATH`.
- **`pip install` fails building from source inside `analysis/venv`.** Usually means no prebuilt wheel exists for your Python version at these floors, which is more likely on very new or very old CPython. `analysis/venv/bin/pip install --upgrade pip` first often surfaces a compatible wheel; if it still falls back to a source build and fails, installing without version constraints (`analysis/venv/bin/pip install pandas numpy matplotlib scipy tabulate statsmodels jinja2`) is a safe fallback, since the analysis phase is not sensitive to exact versions of these.
- **Docker or Compose issues in general** (daemon unreachable, `docker compose` vs `docker-compose`, WSL2-specific PATH quirks) are environment setup rather than something this project can account for. Consult Docker's own docs for your OS if `docker info` itself is not working before troubleshooting anything here.

---

## Experimental design rationale

- **7 repetitions per cell.** Each rep is a full clean-slate restart, so the count is a wall-clock tradeoff against statistical power. At n=7 vs 7 the smallest achievable two-sided Mann-Whitney p-value is `2/C(14,7) = 0.00058`, which still clears α=0.05 after Holm correction across the five adjacent-tier comparisons (0.0029). At n=5 the floor is 0.0079, or 0.0397 corrected: significant, but with no margin for one noisy rep. Achieved N is printed with every result. Below 7 reps, `pairwise_mannwhitney` checks the minimum p-value actually achievable at the realized rep count against alpha and prints a `[!]` when even perfect separation could not clear it (at 2 reps/side the floor is 0.333), so "Significant: No" on a short or smoke run is never misread as an actual null result rather than an underpowered test.
- **Rep-level statistics, not request-level.** Requests within a rep share a JVM, a page cache and a thermal state, so they are not independent. All significance tests rank per-rep means and all CIs are cluster bootstraps that resample whole reps. Pooled request-level p-values appear in table 5 marked *diagnostic only* precisely because they are pseudoreplicated and would overstate significance.
- **Closed-loop load model for the main suite.** `per-vu-iterations` fixes the number of in-flight requests, which is the model that matches a bounded caller pool and avoids unbounded queue growth invalidating high-concurrency cells. Its known cost is coordinated omission, so `run-target-openloop.js` runs a `constant-arrival-rate` check at the top cells and table 7 reports both side by side. Read the open-loop figure as the validity check on the closed-loop tail, not as a competing result.
- **Cells are calibrated to a fixed duration, not a fixed iteration count.** Throughput differs by a large factor between targets, so a flat `ITERATIONS_PER_VU` would make a trivial target's cell span seconds and an AI tier's span minutes at the same nominal setting. `calibrate_target()` measures each target's real throughput and derives the count that makes every cell at VUS 8 and above span about 60s. VUS 1, 2 and 4 keep the flat `SCAN_ITERATIONS_PER_VU` default. Measured throughput is `(N-1)/span`, not `N/span`: N completion timestamps bound N-1 inter-completion intervals, the same convention `analyze-results.py`'s own throughput figures (table 4, figure 4) use, so a calibration cell's derived iteration count and a reported throughput number are the same quantity.
- **Calibration runs once, in its own pass, before the reps it serves.** The pass restarts and warms the stack exactly as a rep does and then measures every target (every cell, in the ablation) without running a measured cell. Every rep of a cell therefore runs the same workload after the same load history: calibrating inside the first rep would give that rep an extra load period the others lack, and calibrating in every rep would let the workload itself vary between reps. Rep-to-rep throughput drift only moves a cell's duration around its 60s target, and table 4e shows how much the cell mean depends on duration at all.
- **Order randomization.** Targets and concurrency levels are shuffled independently per rep, so thermal drift or a background daemon cannot systematically favour whichever target would otherwise always run first.
- **Fixed model hyperparameters.** `max_depth=4`, `learning_rate=0.1`, untuned. Accuracy is never a measured outcome; the model is a stand-in inference workload chosen for its four-tier feature structure. Tuning it would change latency without making any reported claim more valid.
- **Warm-up is gated on convergence, not on a fixed budget.** `converge_warmup()` re-runs warm-up in 15s chunks, up to four, and stops as soon as every target has settled; the verdict after the last chunk is the state the measured phase starts from. The criterion lives in `load-testing/lib/warmup_gate.py`, which both harness scripts, the probes and table 0 all run. Per target, the median of the last window of HTTP 200 latencies is compared with the window before it, and the target passes on whichever bound is looser for its latency scale: a change under 5%, or an absolute gap under 0.25 ms, since a percentage alone is unreachably tight for the sub-millisecond targets. A window is at least 500 requests and at least 3s of that target's own traffic: at the zero-work targets' throughput 500 requests cover tens of milliseconds, shorter than the JVM's GC cycle and scheduler timescales, so two such windows would sample different transient states and read that as drift. Three windows still fit in one chunk at every target's throughput, so the first chunk can pass. Every target the run exercises must converge, and one with no HTTP 200 response never does. If four chunks are not enough, the suite proceeds and records the fact rather than aborting, and table 0 lists every target's verdict, so an under-warmed target is visible rather than silently accepted.
- **Warm-up convergence is judged on the tail.** Table 0 reports both drift from the first window, which is large by design and shows warm-up doing its job, and drift between the last two windows. Only the latter indicates steady state, and only it gates the `Converged` column.
- **Table 1/4/7's request counts, extremes and throughput are corrected for reservoir subsampling.** `load_results()` pools every metric in a results file into one shared subsampling cap; a scan cell logging several metrics per request could have any single metric's own count stay well under the cap while the file's combined point count still tripped it, deflating the reported N and throughput by roughly the subsampling ratio, and a uniform sample almost never keeps a cell's single fastest and slowest request. A true-count side channel tracks the exact pre-subsampling count, time span and value range per cell, independent of what the reservoir kept, and `summarize`/`error_summary`/`_throughput_reqs_per_s` report from it instead of the sample. Table 6's diagnostic-only Pooled N column is the one place this is not wired in -- correcting it without also recomputing its diagnostic p-value against the true full dataset would leave the row internally inconsistent.
- **An open-loop cell where every request fails still gets a table 7 row.** Cell identity (which tiers and rates were actually run) is read from all `http_req_duration` points regardless of status, not just the 200s; a cell so overloaded that nothing succeeded is exactly the case the open-loop check exists to surface, and it reports `N=0` with its `dropped_iterations` count rather than disappearing from the table.

---

## Threats to validity

### Construct validity: does the instrumentation measure what it claims?

- **The `calibration` target measures instrumentation overhead as a floor.** It stays baked into the AI and mock numbers rather than being subtracted out.
- **`modelInferenceTimeMs` covers the whole cost of obtaining a prediction.** It spans the entire `predict_proba` call, and on this software stack that call is dominated by XGBoost's ingestion of the pandas DataFrame rather than by the booster. Micro-benchmarked against the committed artifacts at the pinned dependency versions, tier 28: the complete call is about 3.0 ms, of which the DataFrame to `DMatrix` conversion is about 2.9 ms (95%) and booster traversal about 0.05 ms (2%). The conversion cost is linear in column count, because XGBoost's dtype-inspection path runs per column per call, so the *tier scaling* of this field is predominantly a scaling of framework-level input marshalling. Reported as measured, because that is what a service written this way pays: service-level cost, not model-evaluation cost.
- **The serialization figure is a self-referential estimate.** `totalPythonExecutionTimeMs` includes an EWMA estimate of the cost of serializing the very response that carries it. Table 2's `Serialization (% of total)` column bounds how much that circularity can matter.
- **`estimatedBridgeOverheadMs` is a derived difference across two independent clocks**, so it can go negative. It is deliberately not clamped; table 2 reports the negative rate and minimum per tier. A small, tier-consistent rate is timer noise between processes; a large or tier-clustered rate would be a real measurement fault. `aiCallRoundTripTimeMs`, the clock this is derived from, is timed inside a `Mono.defer` so its own clock starts at subscription rather than at Mono assembly; the field name reflects what it actually measures (see below), not a network hop.
- **It is named for what it is: Docker bridge-network overhead.** It is the bridge and NAT path between two containers on one host, plus that serialization-estimation error, and should not be read as a WAN figure. It is constant across strategies, so it cancels in differential comparisons.
- **Requests can complete below the physical floor.** Table 1e counts model-inference requests faster than the fastest `calibration` request. Anything there is a timing artifact rather than a fast inference, and the affected tier's reported minimum should not be read as a real latency. `mock` is not checked: it adds only a random draw to calibration's path, so the two distributions coincide and about half of mock's fastest requests fall below calibration's single fastest one by sampling alone.
- **`n_jobs=1` is verified at load and again after real inference**, and the BLAS/OpenMP caps (`OMP_NUM_THREADS` and friends) are asserted from `/health` each rep. Together that is a strong, not absolute, single-threading guarantee.
- **The two zero-compute baselines are intrinsically noisier in relative terms.** `mock` and `calibration` cross the same wire as the AI tiers but do no model computation, so there is no compute term to dilute scheduling and queueing jitter, and their coefficient of variation and tail-to-median ratio run well above the AI tiers'. This is a property of what they measure, not a defect: it is why the warm-up gate's window is defined by time rather than by request count, and per-request variance on those two targets should not be read as instability of the harness.

### Internal validity: could something other than the manipulated variable explain the result?

- **Physical-core isolation is verified, not assumed.** `verify_smt_isolation()` resolves each cpuset to physical cores via `thread_siblings_list` and aborts if python, java and k6 overlap. Disjoint cpusets alone do not imply disjoint hardware on an SMT host, and this check is what catches it. **The ablation's cpuset arm is the place this matters most**: widening python-service onto higher-numbered CPUs can land it on the SMT siblings of the cores java and k6 already hold, which would make that arm measure contention rather than core count. Re-pick those values per host.
- **Pinning assumes a native Linux Docker host.** On Docker Desktop (macOS or Windows), `cpuset` inside the VM has no fixed relationship to physical cores.
- **WSL2 specifically: `verify_cpu_pinning()` can pass while pinning is not real.** cgroup `cpuset` is honored inside the WSL2 VM so the requested-vs-live check reports OK, but the Hyper-V host scheduler can still migrate the underlying virtual CPUs across physical cores, and no in-VM check can observe that. `thread_siblings_list` is often not exposed there either, in which case the SMT check reports `unverifiable` rather than passing. `wsl2_detected` and `physical_core_isolation` are recorded in `run_metadata.json` so any affected snapshot is traceable. **This is disclosure, not mitigation; a native-Linux run is the stronger dataset.** Treat concurrency-scan tail claims (E2) as more exposed than the baseline decomposition (E1), since migration risk scales with scheduling pressure.
- **CPU governor and per-core frequency are sampled at both ends of every rep** to `env_trace_log.txt`. Set the governor to `performance` before a run (`sudo cpupower frequency-set -g performance`); `cpu_governor_at_start` in `run_metadata.json` records what was actually in effect.
- **Thermal state is measured per cell, and guarded.** Temperature and the kernel's thermal-throttle counters are recorded at both edges of every measured cell, so table 8a (and its ablation counterpart) shows whether any service's cores were throttled during a cell, table 8b what the thermal pauses cost, and table 8c whether temperature or throttling tracks a cell's latency within its design cell. Throttling is measured where the host exposes Intel's `thermal_throttle` counters (Linux 5.18+) and reported as `not exposed` elsewhere, never as zero. The guard also pauses the run at 90C and aborts at 95C after two cooldowns, so a heat-soaked laptop stops rather than contributing cells it cannot cool. Randomized target, concurrency and cell order keeps residual heat from aligning with any one condition.
- **`isolcpus`, AC/battery power, and `irqbalance` are recorded but not enforced.** All three can shift measured latency without appearing anywhere in this project's own configuration, so `host-provenance.sh` samples them into `run_metadata.json` every rep. This is disclosure rather than a guarantee: a run on battery power or with `irqbalance` active is not blocked, so check `run_metadata.json` before treating two runs as comparable.
- **GC pause overhead is measured, not eliminated.** `table_gc_overhead` reports per-rep GC pause time as a percentage of wall clock. A rep above about 1%, or with a single pause near the P99, is a candidate confound for that rep's tail rather than inference cost.
- **k6 is pinned to its own cpuset and capped at 4 CPUs.** That stops direct cgroup-level contention with the services under test, but does not isolate any of the three from the Docker daemon or the rest of the host OS, which remain unpinned. `http_req_blocked` (tables 1d and 4d) is a partial diagnostic only; it cannot independently prove k6 never became the bottleneck at high concurrency.
- **The Java outbound connection pool is sized at 2x the run's peak VUS** by both harness scripts, so pool queueing cannot masquerade as network or Python cost. A hand-started stack falls back to the 128 default.
- **OOM kills abort the suite** per cell rather than being logged and skipped, as do cpu-pin, tier and thread-env failures. There are no partial runs.

### External validity: how far do the results generalize?

- **Single-node only**, with no multi-region or real network-hop path.
- **Every inference call is one row in, one prediction out.** There is no batching path anywhere in `fraud-ml-service`. Results characterize unbatched synchronous-call overhead and say nothing about batched or dynamically-batched serving.
- **Synthetic, uniformly-random feature vectors.** The licensed dataset cannot be bundled, so `randomFeatures()` draws in a roughly PCA-shaped range. Two things bound the exposure: booster traversal is structure-dominated (measured flat at 0.04 to 0.05 ms across all four tiers, against a depth-4, 100-tree model), and the term that actually dominates `modelInferenceTimeMs`, the DataFrame to `DMatrix` conversion, is a dtype-and-shape operation independent of the values. The feature distribution therefore has little influence on the measured cost, though the models were trained on real data and their tree structure reflects it.
- **Reduced feature space even at the largest tier.** `V1..V28` plus `Amount` is the full PCA set available, but the source dataset is itself a reduced anonymized representation.
- **Core pinning is host-specific.** Results are not comparable across different core counts or SMT settings without re-picking `cpuset` values, and the SMT check will abort rather than silently produce incomparable numbers.
- **Concurrency-scan P99s are not uniformly powered.** Cells at VUS 8 and above are calibrated to a fixed wall-clock duration rather than a fixed sample count, so total N varies by target; VUS 1, 2 and 4 use the flat `SCAN_ITERATIONS_PER_VU` instead. P99 confidence intervals therefore differ in width across a row. Do not read a row of per-concurrency P99s as equally precise; the achieved N is printed alongside every result.
- **Mock and calibration are latency baselines only**, never real fraud checks. `--synthetic` training data is a smoke test, not a benchmark source.
- **In-memory H2** is wiped on restart, and the top-level log files reflect the last run only. `run_metadata.json`, `run_order_log.txt`, `run_failures_log.txt`, `cpu_pin_check_log.txt` and `env_trace_log.txt` (and their `ablation_`-prefixed counterparts) are written fresh each run, with the previous run's copies moved into `results/archive/<timestamp>/`.

---

## Structure

```
.
├── docker-compose.yml
├── setup.sh                       # once per machine: .env (HOST_UID/GID), results/gc-logs/, analysis/venv
├── install-test-deps.sh           # once per machine: every *test* toolchain below, in one pass
├── analysis/
│   ├── analyze-results.py        # tables, figures, significance tests
│   ├── analyze-ablation.py       # thread-dispatch mechanism sweep
│   ├── lib/
│   │   ├── warmup_check.py       # table 0 for both scripts, judged by load-testing/lib/warmup_gate.py
│   │   └── thermal.py            # per-cell thermal state, pauses, thermal-latency association
│   ├── probing/
│   │   └── plot_warmup_curve.py  # thermal diagnostic: latency vs VUs, temp and core frequency
│   ├── tests/                    # pytest (115): analysis pipeline, warm-up gate, k6 filter, thermal
│   ├── requirements.txt
│   └── requirements-dev.txt      # test-only: pytest, kept off analyze-*.py's real runtime deps
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── run-ablation.sh           # four-arm thread-dispatch mechanism sweep
│   ├── run-smoke-test.sh         # small pipeline-check pass before the full suite
│   ├── recommend-cpusets.sh      # prints cpuset values fitting this host's topology
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner (closed-loop)
│   ├── run-target-openloop.js    # manual constant-arrival-rate check, top concurrency cells only
│   ├── lib/
│   │   ├── common.js             # shared sendTransaction()/TARGETS + telemetry Trends
│   │   ├── topology.sh           # cpuset to physical-core resolution; SMT-overlap/cpuset-quota guards
│   │   ├── jvm-pins.sh           # verifies G1/thread-pool ceilings against the JVM's own flag origin
│   │   ├── host-provenance.sh    # isolcpus/power-source/irqbalance sampling for run_metadata.json
│   │   ├── thermal.sh            # thermal guard, per-cell temperature and throttle telemetry
│   │   ├── warmup_gate.py        # warm-up convergence criterion shared by the gate, probes and table 0
│   │   └── k6_filter.py          # keeps the metrics the analysis reads and gzips each result
│   ├── probing/                  # standalone diagnostics, not wired into the suite
│   │   ├── probe_warmup_joint.sh         # all six targets, past the chunk cap, per-target tail drift
│   │   ├── probe_warmup_settle.sh        # one target, past the cap, widenable criterion
│   │   ├── calibrate_scan_iterations.sh  # per-host ITERATIONS_PER_VU derivation
│   │   ├── probe_calibration_drift.sh    # checks calibrated throughput actually holds across reps
│   │   ├── probe_ablation_taper.sh       # per-arm cell-duration check
│   │   └── probe_telemetry_completeness.sh  # per-target telemetry field presence, build-freshness check
│   └── tests/                    # bats-core (90): topology, JVM pins, shared helpers, warm-up gate, calibration, thermal
├── fault-injection/
│   ├── verify-guards.sh          # runs each case, records whether the expected guard fired
│   ├── cases/*.case              # 9 cases: 00 unmodified as control, 01-08 each misconfigure one pinned setting
│   └── results/guard_verification_report.{md,csv}
├── results/                       # generated: *.json.gz, run_metadata.json, logs (gitignored except .gitkeep)
│   ├── raw/                       # k6's unfiltered output, deleted per cell after filtering
│   ├── archive/<timestamp>/       # previous run's files, moved aside at the start of a new run
│   └── gc-logs/                   # generated: gc_<phase>_rep{N}.log per repetition
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR, numeric thread env
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py, calibration.py
    │   ├── tests/                   # pytest (50): timing invariants, EWMA, telemetry symmetry
    │   ├── requirements-dev.txt     # test-only deps, kept out of the service image
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/
            ├── main/java/.../{config,controller,service,model,repository,dto,exception,filter}/
            └── test/java/.../       # JUnit: overhead derivation, routing, timing filter
```

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock/calibration routing, load testing, and telemetry/concurrency work by [MuhammadHussain06](https://github.com/MuhammadHussain06), integrating and extending both.
