# AI Inference Overhead Harness

A containerized testbed that measures the **latency and throughput cost of a live AI fraud-inference call**, benchmarked against a network-equivalent mock and a zero-work calibration floor.

```bash
docker compose up          # bring up the stack
./load-testing/run-suite.sh              # run the full benchmark suite
python3 analysis/analyze-results.py      # generate tables + figures
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
- [Tests](#tests)
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
| `DISTRIBUTED_CALIBRATION_ONLY` | No business logic at all — not even a random draw | Isolates the harness's own instrumentation floor |

This separation lets you attribute latency precisely:

- **Mock − Calibration** ≈ cost of one random draw
- **AI tier − Calibration** ≈ DataFrame construction + model inference
- DB persistence (`APP_DB_SAVE_ENABLED=false`) is off for all benchmark runs, so writes never enter the measured path
- In-memory H2 — every run starts from a clean slate

---

## Scope

**This testbed answers:** in a synchronous, single-node, single-request microservice call, how much of end-to-end latency is model compute versus everything else (network, framework, serialization, queueing) — and how that ratio shifts with model complexity (feature-tier) and concurrency.

**It deliberately does not answer:** batched or dynamic-batching inference cost (every call is a single row in, single prediction out — see [Threats to validity](#threats-to-validity)), multi-model or multi-tenant serving, GPU-backed inference, multi-region/network-hop latency, or production fraud-detection accuracy (accuracy is never measured — the fraud-detection model is an incidental stand-in workload chosen for its four-tier feature-count structure, not for its domain).

---

## Research questions

| | Question | Answered by |
|---|---|---|
| **RQ1** | In a synchronous microservice call, how does end-to-end latency decompose across model inference, DataFrame construction, thread dispatch, framework overhead, and the network hop? | E1 baseline (`run-suite.sh`), tables 1–3, figures 1–2 |
| **RQ2** | How does that decomposition shift with model complexity (feature-count tier) and with request concurrency? | E1 across tiers + E2 concurrency scan, tables 4–5, figures 3–5 |
| **RQ3** | Which system-level mechanism — thread-limiter capacity, available core count, or process count (GIL) — drives the thread-dispatch cost that dominates at high concurrency? | Ablation (`run-ablation.sh`), `analyze-ablation.py` |

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

- Stage-by-stage latency nested in every response — parsing, network, DB write, response build, serialization (Java); parsing, thread dispatch, DataFrame construction, model inference, compute stall, serialization (Python).
- Timeouts/connection errors (`status=0`) tracked separately from HTTP errors.
- Client-side connection contention (`http_req_blocked`) reported as its own diagnostic, so a throughput plateau can be checked against the load generator before blaming server capacity.
</details>

<details>
<summary><b>Isolation and verification</b></summary>

- Reactive Java stack end to end (WebFlux + R2DBC).
- CPU pinning verified per repetition against each container's *live* cgroup cpuset — not just the requested compose config.
- Physical-core isolation verified before any container starts: each cpuset is resolved to physical cores via `thread_siblings_list`, and the suite aborts if python, java and k6 turn out to share cores through SMT siblings. Disjoint cpusets do not imply disjoint hardware.
- Model inference pinned to `n_jobs=1`, read back at load *and* re-read after real inference (`nJobsVerified` / `nJobsRuntimeVerified` on `/health`). `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, `NUMEXPR_NUM_THREADS` are pinned to 1 and asserted from `/health` each rep — `n_jobs` alone does not constrain the BLAS layer beneath it.
- CPU governor and per-core frequency sampled at both ends of every repetition to `env_trace_log.txt`, so mid-suite thermal throttling is attributable to a specific rep.
- Valid feature-tier set is fetched from `fraud-ml-service`'s `/health` at startup — never hardcoded in Java. `run-suite.sh` re-verifies this per rep (`loadedTiers` matches expected, `nJobsVerified` all true) and aborts the suite if it doesn't.
- Outbound Java→Python connection pool is sized by the harness at 2× the run's peak VUS (`PYTHON_SERVICE_MAX_CONNECTIONS`), so it can never become the bottleneck being measured, and is logged at startup. A hand-started stack falls back to `128`.
- In-memory H2 — clean slate every run.
- Per-request logging is off on both services (Java: `TransactionService` at `WARN`; Python: `uvicorn --no-access-log`) — a synchronous stdout write on the WebFlux event loop or the request coroutine would otherwise stall it, adding latency/throughput noise unrelated to inference.
- JVM GC events are logged continuously to `results/gc-logs/gc_<phase>_rep<N>.log` (one file per rep, archived by `run-suite.sh` before the next rep's JVM overwrites `gc.log`) — lets tail-latency spikes be cross-checked against GC pauses. Unified JVM logging has negligible overhead and doesn't sit on the request path.
</details>

<details>
<summary><b>Orchestration and analysis</b></summary>

- `run-suite.sh`: full baseline + concurrency-scan suite across clean-slate restarts, with per-repetition target/concurrency shuffling, CPU-pin verification, host/toolchain provenance fingerprinting, and a failures log so one broken cell doesn't abort the run.
- `warm-up.js`: JIT/pool warm-up once per restart, hitting every target sequentially in its own window (plus a second max-VUS pass before the concurrency scan). Shares code with `run-target.js` so warm-up traffic is tagged and classified identically to measured traffic.
- `analyze-results.py`: P50/P95/P99 tables and histograms per strategy/tier, Mann-Whitney U significance testing (Holm-Bonferroni corrected, rank-biserial effect sizes), cluster-level bootstrap CIs, reproducibility (CoV% across reps), paired error/timeout tables, client-contention diagnostics, warm-up convergence checks, throughput-vs-concurrency figures, and an optional open-loop-vs-closed-loop validity check (see [Running](#running)) when `openloop_*.json` files are present.
</details>

---

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud) — anonymized European transactions, September 2013.

- Each tier uses the first `n` of 28 `V` PCA components (`V1..Vn`) plus `Amount` (`log1p`-transformed). `V10` is a strict superset of `V5`, and so on.
- Highly imbalanced (~0.17% fraud); trained with SMOTE oversampling, then `XGBClassifier`, independently per tier.
- Pretrained models for all four tiers are committed under `services/fraud-ml-service/models/` — `docker compose up` works with no training step.
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

Clients always send the full `V1..V28` vector, regardless of tier — each endpoint just slices what it needs, so one request body works against any tier. Mock and calibration ignore `features` entirely.

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

- `featureTier` selects the model (`V5`/`V10`/`V20`/`V28`); **required** for `DISTRIBUTED_AI_SYNCHRONOUS`, ignored otherwise.
- `features` must contain at least `featureTier` values.
- `transactionId` must be a UUID; `accountId` must match `ACC-\d{4,10}` — both validated before reaching the AI layer. Invalid requests get a `400` with per-field errors.

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
| `estimatedNetworkOverheadMs` | `aiCallRoundTripTimeMs` − Python's `totalPythonExecutionTimeMs`: transit, FastAPI routing, queuing, outbound-pool wait |
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

> `serializationResponseTimeMs` and `totalPythonExecutionTimeMs` are estimates — a response can't report the cost of serializing itself without a prior serialization pass.

---

## Containerization & Hardware

| | python-service | transaction-service | k6 (load generator) |
|---|---|---|---|
| Image | `python:3.11-slim` | build `eclipse-temurin:21-jdk-alpine`, run `21-jre-alpine` | `grafana/k6` |
| Port | `8000` | `8080` | — |
| Cores | `0-2` | `3-5` | `6-7` |
| Limit / reserved | 3.0 CPU / 3G RAM (1.0 / 1G) | 3.0 CPU / 3G RAM (1.0 / 1G) | 2.0 CPU / 1G RAM |
| Notes | `UVICORN_WORKERS=3` at benchmark time; `n_jobs=1` + BLAS env vars keep each `predict_proba` call single-threaded — independent from the 3-worker concurrency | Outbound pool to Python sized via `python.service.max-connections` (default `128`); must stay ≥ highest VUS in `run-suite.sh`'s `CONCURRENCY_LEVELS` (currently `64`) or queueing inflates `estimatedNetworkOverheadMs`. `python.service.pending-acquire-timeout-ms` (default `5000`) bounds the wait. Feature-tier set fetched from Python's `/health` at startup, retrying up to 60s. Heap fixed via `JAVA_TOOL_OPTIONS=-Xms1536m -Xmx1536m` for reproducible sizing across hosts/reps | Runs in its own container on a disjoint cpuset. Gated behind the `loadgen` Compose profile; invoked per-cell by `run-suite.sh` via `docker compose run`, not started by `docker compose up` |

Resource limits (`mem_limit`/`mem_reservation`/`cpus`) use Compose's plain (non-Swarm) top-level keys rather than `deploy.resources.limits`, which is a Swarm-only directive silently unenforced by `docker compose up`.

**Requirements**

- Docker + Docker Compose v2 (`docker compose`)
- 8+ logical cores (`cpuset` hardcoded to `0-2`/`3-5`/`6-7` across the three containers — adjust or drop on smaller machines)
- ~7GB free RAM
- k6 runs containerized (`grafana/k6`, pulled automatically on first `run-suite.sh` invocation) — no host install needed
- Python 3 on the host — required by `run-suite.sh` itself (tier verification) in addition to `pip install -r analysis/requirements.txt` (pandas, numpy, matplotlib, scipy, statsmodels, tabulate) for the analysis phase. `requirements.txt` pins floors, not ceilings — recent CPython (3.13+) needs recent-enough wheels of these anyway, and older exact pins can fail a from-source build on a newer compiler toolchain
- No GPU required

---

## Running

### Smoke test (recommended before the full suite)

A small, fast pass through the same verified pipeline — 2 targets, 2 concurrency levels, 2 reps, reduced iteration counts — to catch a structural problem (bad config, a broken tag, a mislabeled tier) in minutes instead of hours into a real run. Also fires one deliberately over-rate open-loop request to confirm `dropped_iterations` is actually detected.

```bash
docker compose up -d
cd load-testing
./run-smoke-test.sh
```

Check `run_failures_log.txt` and `cpu_pin_check_log.txt` afterward, and confirm `table7_openloop_validity_check` shows a nonzero dropped-iterations count for the smoke-openloop cell. Clean here means the pipeline is trustworthy, not that any given rep count is sufficient — re-run the smoke test after any fix until it passes, then move to the full suite.

`run-suite.sh`'s `TARGETS`, `CONCURRENCY_LEVELS`, `REPS_BASELINE`, `REPS_SCAN`, `BASELINE_ITERATIONS`, and `SCAN_ITERATIONS_PER_VU` are all overridable via `TARGETS_OVERRIDE`, `CONCURRENCY_OVERRIDE`, `REPS_BASELINE_OVERRIDE`, `REPS_SCAN_OVERRIDE`, `BASELINE_ITERATIONS_OVERRIDE`, and `SCAN_ITERATIONS_PER_VU_OVERRIDE` env vars — `run-smoke-test.sh` is a thin wrapper setting these to a small slice; unset, `run-suite.sh` behaves exactly as before.

### Full suite (recommended)

Restarts the stack per repetition, shuffles order, logs provenance.

```bash
docker compose build
pip install -r analysis/requirements.txt
cd load-testing
./run-suite.sh                              # baseline + concurrency scan, all reps
python3 ../analysis/analyze-results.py      # tables + figures
```

Requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`.

`run-suite.sh` runs `warm-up.js` at the start of every restart (plus an extra max-VUS pass before the concurrency scan), then drives `run-target.js` per target/concurrency cell across `mock`, `calibration`, and the four AI tiers. Output:

| File | Contents |
|---|---|
| `results/*.json` | One file per (target, concurrency, rep) cell |
| `run_order_log.txt` | Shuffle order per repetition |
| `run_metadata.json` | Timestamp, Docker/Compose versions, git commit + dirty flag, CPU/RAM, CPU governor/frequency snapshot |
| `cpu_pin_check_log.txt` | Per-repetition requested-vs-live cpuset |
| `warmup_*_rep{N}.json` | Warm-up latency, tagged `phase=warmup`, for convergence checks |
| `gc-logs/gc_<phase>_rep{N}.log` | JVM GC events for that rep's transaction-service lifetime |

### CPU pinning verification

`cpuset` in `docker-compose.yml` states what pinning was *requested*; it doesn't guarantee the cgroup driver honored it. Each repetition, `run-suite.sh` compares:

- **Requested** — `docker inspect --format '{{.HostConfig.CpusetCpus}}'`
- **Live** — `docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective` (cgroup v2, falling back to the v1 path)

A mismatch or empty value aborts the whole suite immediately (`abort_suite`) — no results are written for that rep, and prior reps already on disk are unaffected.

`run-suite.sh` also verifies python-service's feature-tier loading each rep, via its own `/health` endpoint: the reported `loadedTiers` must match `5,10,20,28` (python-service loads every `FEATURE_TIERS` entry from `docker-compose.yml` on every start, regardless of which subset of targets this run exercises), and `nJobsVerified` must be true for every tier. A silent tier-load failure would otherwise corrupt AI-tier cells without ever showing up as a request-level error. Same abort behavior as a cpu-pin mismatch.

Any cell failure (dropped connection, transient error, OOM kill) aborts the suite the same way, rather than logging it and continuing — `analyze-results.py` rejects the whole dataset if `run_failures_log.txt` has any entries regardless, so there's no benefit to continuing past the first one. Fix the cause and re-run the suite for a clean dataset.

### Manual / one-off run

```bash
docker compose up                                    # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
k6 run --out json=results/results.json your-test.js  # real load test
python3 analysis/analyze-results.py                  # tables + figures
```

`warm-up.js` is tunable via `WARMUP_ITERATIONS_PER_TARGET`, `WARMUP_VUS`, `WARMUP_MAX_DURATION_S`, and reads `BASE_URL` (falls back to `http://localhost:8080/api/v1/transactions`).

### Open-loop validity check (optional)

The main suite's concurrency scan is closed-loop (see [Threats to validity](#threats-to-validity)). `run-target-openloop.js` runs the same target under a `constant-arrival-rate` executor instead, so requests fire on a fixed schedule regardless of how fast responses come back — this is the standard mitigation for coordinated omission. Run it against the top 1–2 concurrency cells only, after the main suite, as a check on whether the closed-loop tail-latency numbers hold up:

```bash
docker compose up
k6 run load-testing/warm-up.js
TARGET=28 RATE=32 TIME_UNIT=1s DURATION=2m PRE_ALLOCATED_VUS=64 MAX_VUS=128 \
  k6 run --out json=results/openloop_28_rate32.json load-testing/run-target-openloop.js
```

`RATE` is requests per `TIME_UNIT` — set it to roughly the throughput the closed-loop cell achieved at that VUS level, not the VUS count itself. `PRE_ALLOCATED_VUS`/`MAX_VUS` must be generous enough to sustain `RATE` if response times climb; k6 logs a `dropped_iterations` warning if it runs out of headroom, which itself is diagnostic (it means the server can't sustain that arrival rate — a real finding, not a script bug). This script is standalone and manual by design — it is not invoked by `run-suite.sh` and does not replace the main suite.

Output filenames must start with `openloop` (e.g. `openloop_28_rate32.json`) — `analyze-results.py` detects any such files in `--results-dir`, and if present, adds `table7_openloop_validity_check` and `figure7_openloop_validity_check` comparing open-loop P95/P99 against the closed-loop scan at VUS 32/64 for the same tier. If no `openloop_*` files are present, this step is skipped silently and the rest of the analysis is unaffected.

---

## Tests

The measurement instruments are unit-tested, since every reported figure depends on them
being correct. Neither suite runs during the Docker build — the images stay free of test
tooling and the measured containers stay identical to what is shipped.

```bash
# Python service (47 tests): timing invariants, EWMA convergence,
# n_jobs pinning, telemetry symmetry across the three strategies
cd services/fraud-ml-service
pip install -r requirements-dev.txt
python3 -m pytest tests/ -q

# Java service: network-overhead derivation, telemetry pass-through,
# strategy routing, request-timing filter ordering
cd services/transaction-service
./mvnw test
```

What they guard, and why it matters for the results:

| Test | Protects |
|---|---|
| `test_responses.py` convergence tests | The EWMA serialization estimate stays sub-millisecond and cannot drift, bounding the circularity in `totalPythonExecutionTimeMs` |
| `test_model.py` timing invariants | Compute stall is never negative and never exceeds wall time; computation covers its own components |
| `test_api.py` telemetry symmetry | All three strategies emit identical telemetry fields — the precondition for decomposition by subtraction |
| `test_api.py` baseline-floor tests | `mock` and `calibration` genuinely report zero compute, so they bound inference cost |
| `TransactionServiceTest` overhead tests | `estimatedNetworkOverheadMs` is exactly round-trip minus Python total, and negative values are preserved rather than hidden |
| `RequestTimingWebFilterTest` | The request-start stamp anchoring every Java-side figure is taken at highest filter precedence |

---

### Troubleshooting

- **`permission denied` writing to `/results/*.json` from inside the k6 container.** The `grafana/k6` image runs as a non-root user internally, so a host `results/` directory owned by your user with default permissions can block its writes on a bind mount. Fix with `chmod -R 777 results/` before running.
- **`Conflict. The container name "/..." is already in use`** on `docker compose up`. Leftover stopped containers from an earlier interrupted run are holding a name. `docker ps -a`, then `docker rm` the stale container(s), then retry.
- **`pip install -r analysis/requirements.txt` fails building from source.** Usually means no prebuilt wheel exists for your Python version at these floors — this is more likely on very new or very old CPython. Upgrading pip first (`pip install --upgrade pip`) often surfaces a compatible wheel; if it still falls back to a source build and fails, installing without version constraints (`pip install pandas numpy matplotlib scipy tabulate statsmodels`) is a safe fallback — the analysis phase isn't sensitive to exact versions of these.
- **Docker/Compose issues in general** (daemon unreachable, `docker compose` vs `docker-compose`, WSL2-specific PATH quirks) are environment setup, not something this project can account for — consult Docker's own docs for your OS if `docker info` itself isn't working before troubleshooting anything here.

---

## Experimental design rationale

Choices a reviewer is likely to ask about, and why they were made.

- **7 repetitions per cell.** Each rep is a full clean-slate restart, so the count is a wall-clock tradeoff against statistical power. At n=7 vs 7 the smallest achievable two-sided Mann-Whitney p-value is `2/C(14,7) = 0.00058`, which still clears α=0.05 after Holm correction across the five adjacent-tier comparisons (0.0029). At n=5 the floor is 0.0079, or 0.0397 corrected — significant, but with no margin for one noisy rep. Achieved N is printed with every result.
- **Rep-level statistics, not request-level.** Requests within a rep share a JVM, a page cache and a thermal state, so they are not independent. All significance tests rank per-rep means and all CIs are cluster bootstraps that resample whole reps. Pooled request-level p-values appear in table 5 marked *diagnostic only* precisely because they are pseudoreplicated and would overstate significance.
- **Closed-loop load model for the main suite.** `per-vu-iterations` fixes the number of in-flight requests, which is the model that matches a bounded caller pool and avoids unbounded queue growth invalidating high-concurrency cells. Its known cost is coordinated omission, so `run-target-openloop.js` runs a `constant-arrival-rate` check at the top cells; table 7 reports both side by side. Read the open-loop figure as the validity check on the closed-loop tail, not as a competing result.
- **Order randomization.** Targets and concurrency levels are shuffled independently per rep, so thermal drift or a background daemon cannot systematically favour whichever target would otherwise always run first.
- **Fixed model hyperparameters.** `max_depth=4`, `learning_rate=0.1`, untuned. Accuracy is never a measured outcome; the model is a stand-in inference workload chosen for its four-tier feature structure. Tuning it would change latency without making any reported claim more valid.
- **Warm-up convergence is judged on the tail.** Table 0 reports both drift from the first window (large by design — that is warm-up working) and drift between the last two windows. Only the latter indicates steady state, and only it gates the `Converged` column.

---

## Threats to validity

### Construct validity — does the instrumentation measure what it claims?

- **Instrumentation overhead is measured, not removed.** The `calibration` target bounds it as a floor; it stays baked into the AI and mock numbers.
- **The serialization figure is a self-referential estimate.** `totalPythonExecutionTimeMs` includes an EWMA estimate of the cost of serializing the very response that carries it. Table 2's `Serialization (% of total)` column bounds how much that circularity can matter — sub-1% of total on every AI tier in practice.
- **`estimatedNetworkOverheadMs` is a derived difference across two independent clocks**, so it can go negative. It is deliberately not clamped; table 2 reports the negative rate and minimum per tier. A small, tier-consistent rate is timer noise between processes, a large or tier-clustered rate would be a real measurement fault.
- **"Network overhead" is Docker bridge-network overhead**, not a real network hop — the bridge/NAT path between two containers on one host, plus that serialization-estimation error. It is constant across strategies, so it cancels in differential comparisons but should not be read as a WAN figure.
- **Requests can complete below the physical floor.** Table 1e counts requests faster than the fastest `calibration` request; anything there is a timing artifact, not a fast inference, and the affected tier's reported minimum should not be read as a real latency.
- **`n_jobs=1` is verified at load and again after real inference**, and the BLAS/OpenMP caps (`OMP_NUM_THREADS` and friends) are asserted from `/health` each rep. Together that is a strong, not absolute, single-threading guarantee.

### Internal validity — could something other than the manipulated variable explain the result?

- **Physical-core isolation is verified, not assumed.** `verify_smt_isolation()` resolves each cpuset to physical cores via `thread_siblings_list` and aborts if python, java and k6 overlap. Disjoint cpusets alone do not imply disjoint hardware on an SMT host, and this check is what catches it. **The ablation's cpuset arm is the place this matters most** — widening python-service onto higher-numbered CPUs can land it on the SMT siblings of the cores java and k6 already hold, which would make that arm measure contention rather than core count. Re-pick those values per host.
- **Pinning assumes a native Linux Docker host.** On Docker Desktop (macOS/Windows), `cpuset` inside the VM has no fixed relationship to physical cores.
- **WSL2 specifically: `verify_cpu_pinning()` can pass while pinning is not real.** cgroup `cpuset` is honored inside the WSL2 VM so the requested-vs-live check reports OK, but the Hyper-V host scheduler can still migrate the underlying virtual CPUs across physical cores, and no in-VM check can observe that. `thread_siblings_list` is often not exposed there either, in which case the SMT check reports `unverifiable` rather than passing. `wsl2_detected` and `physical_core_isolation` are recorded in `run_metadata.json` so any affected snapshot is traceable. **This is disclosure, not mitigation — a native-Linux run is the stronger dataset.** Treat concurrency-scan tail claims (E2) as more exposed than the baseline decomposition (E1), since migration risk scales with scheduling pressure.
- **CPU governor and per-core frequency are sampled at both ends of every rep** to `env_trace_log.txt`, so mid-suite thermal throttling is attributable to a specific rep rather than inferred from one opening snapshot.
- **GC pause overhead is measured, not eliminated.** `table_gc_overhead` reports per-rep GC pause time as a % of wall-clock; a rep above ~1%, or with a single pause near the P99, is a candidate confound for that rep's tail rather than inference cost.
- **k6 is pinned to its own cpuset and capped at 2 CPUs.** That stops direct cgroup-level contention with the services under test, but does not isolate any of the three from the Docker daemon or the rest of the host OS, which remain unpinned. `http_req_blocked` (tables 1d/4d) is a partial diagnostic only — it cannot independently prove k6 never became the bottleneck at high concurrency.
- **The Java outbound connection pool is sized at 2× the run's peak VUS** by both harness scripts, so pool queueing cannot masquerade as network or Python cost. A hand-started stack falls back to the 128 default.
- **OOM kills abort the suite** per cell rather than being logged and skipped, as do cpu-pin, tier and thread-env failures. There are no partial runs.

### External validity — how far do the results generalize?

- **Single-node only** — no multi-region or real network-hop path.
- **Every inference call is one row in, one prediction out.** There is no batching path anywhere in `fraud-ml-service`. Results characterize unbatched synchronous-call overhead and say nothing about batched or dynamically-batched serving.
- **Synthetic, uniformly-random feature vectors.** The licensed dataset cannot be bundled, so `randomFeatures()` draws in a roughly PCA-shaped range. XGBoost traversal cost is dominated by tree structure rather than input values, but this is an assumption the results rest on rather than a verified property.
- **Reduced feature space even at the largest tier** — `V1..V28` + `Amount` is the full PCA set available, but the source dataset is itself a reduced anonymized representation.
- **Core pinning is host-specific.** Results are not comparable across different core counts or SMT settings without re-picking `cpuset` values, and the SMT check will abort rather than silently produce incomparable numbers.
- **Concurrency-scan P99s are not uniformly powered.** `ITERATIONS_PER_VU` holds per-VU sample count constant while total N grows with VUS (100 at VUS=1, 6400 at VUS=64, by design, to resolve tails under contention). P99 confidence intervals widen at lower concurrency; do not read a row of per-concurrency P99s as equally precise.
- **Mock and calibration are latency baselines only** — never real fraud checks. `--synthetic` training data is a smoke test, not a benchmark source.
- **In-memory H2** is wiped on restart, and all log files reflect the last run only (`run_metadata.json`, `run_order_log.txt`, `run_failures_log.txt`, `cpu_pin_check_log.txt`, `env_trace_log.txt` are truncated fresh each run). Export `results/` before tearing down.

---

## Structure

```
.
├── docker-compose.yml
├── analysis/
│   ├── analyze-results.py        # tables, figures, significance tests
│   ├── analyze-ablation.py       # thread-dispatch mechanism sweep
│   └── requirements.txt
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── run-ablation.sh           # three-arm thread-dispatch mechanism sweep
│   ├── run-smoke-test.sh         # small pipeline-check pass before the full suite
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner (closed-loop)
│   ├── run-target-openloop.js    # manual constant-arrival-rate check, top concurrency cells only
│   └── lib/common.js             # shared sendTransaction()/TARGETS + telemetry Trends
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR, numeric thread env
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py, calibration.py
    │   ├── tests/                   # pytest: timing invariants, EWMA, telemetry symmetry
    │   ├── requirements-dev.txt     # test-only deps, kept out of the service image
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/
            ├── main/java/.../{controller,service,model,repository,dto,exception,filter}/
            └── test/java/.../       # JUnit: overhead derivation, routing, timing filter
```

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock/calibration routing, load testing, and telemetry/concurrency work by [MuhammadHussain06](https://github.com/MuhammadHussain06), integrating and extending both.
