# AI Inference Overhead Harness: Containerized Testbed

Containerized testbed for measuring the latency and throughput cost of a
live AI fraud-inference call, benchmarked against a network-equivalent
mock baseline and a zero-work calibration floor. `docker compose up`
brings the stack up. `run-suite.sh` and `analyze-results.py` reproduce
the full load-test results (see [Running](#running)).

Combines two services:

- **transaction-service** (Java, Spring Boot). Reactive REST API that
  validates and routes transactions and records latency telemetry.
- **fraud-ml-service** (Python, FastAPI). Wraps a trained XGBoost fraud
  classifier.

This repo containerizes both services, adds mock and calibration
endpoints for isolating AI overhead, pins CPUs per service, and ships k6
load testing plus statistical result analysis.

## Idea

Every transaction is scored by one of three strategies:

- `DISTRIBUTED_AI_SYNCHRONOUS`: scored by a real XGBoost model at a
  chosen feature-count tier (see below).
- `DISTRIBUTED_MOCK_GATEWAY`: scored by a random-value mock, with the
  same request/response shape and network path as the real model call.
- `DISTRIBUTED_CALIBRATION_ONLY`: no business logic at all, not even the
  mock's random draw. Isolates the harness's own instrumentation and
  serialization overhead as a measurable floor.

All three strategies share the same JVM, network hop, and DTOs, so the
difference between them isolates model-inference cost from fixed costs
(HTTP, serialization, scheduling) and from the harness's own measurement
overhead. DB persistence (`APP_DB_SAVE_ENABLED`) is off for benchmark
runs (see [Running](#running)), so the DB write is not part of any
path's measured cost. The AI strategy also selects across four
input-size tiers, `V5`, `V10`, `V20`, `V28`, so inference cost can be
measured as a function of feature-vector size.

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

Each service runs in its own container, pinned to a disjoint CPU range,
so the two never contend for the same cores during a run.

## Features

- Three-way strategy routing (`AI` / `mock` / `calibration`), selected
  per request via the `strategy` field.
- Four feature-count tiers for the AI strategy (`5`/`10`/`20`/`28`),
  selected per request via `featureTier` and routed to
  `/predict/v{tier}`. Each tier is its own XGBoost model, loaded once at
  startup and held in memory alongside the others.
- Stage-by-stage latency, all nested in one response: parsing, network,
  DB write, response-object build, and serialization on the Java side;
  parsing, thread dispatch, computation (split into DataFrame
  construction and model inference), compute stall (GIL/scheduling), and
  serialization on the Python side.
- A `calibration` target that runs the full request/response pipeline
  with no computation behind it, so mock's marginal cost over
  calibration is roughly one random draw, and each AI tier's marginal
  cost over calibration is its DataFrame construction plus inference.
- Reactive Java stack end to end (WebFlux and R2DBC).
- CPU-pinned, resource-limited containers. Pinning is verified per
  repetition against each container's live cgroup cpuset, not just the
  requested compose configuration.
- Model inference pinned to `n_jobs=1` at load time, read back and
  verified rather than assumed, exposed per tier on `/health` as
  `nJobsVerified`. The Python container also pins `OMP_NUM_THREADS`,
  `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, and `NUMEXPR_NUM_THREADS` to
  1, guarding against BLAS-level thread contention beneath the
  sklearn/XGBoost wrapper.
- The valid feature-tier set is fetched from `fraud-ml-service`'s
  `/health` endpoint at startup (`FeatureTierRegistry`), not hardcoded
  in Java, so the two services cannot silently disagree on which tiers
  exist.
- The outbound Java to Python connection pool is explicitly sized
  (`python.service.max-connections`, default `128`) and logged at
  startup, so pool exhaustion under load is a distinguishable, bounded
  failure rather than an invisible source of latency.
- Timeouts and connection errors (`status=0`) are tracked separately
  from HTTP errors, both in the raw k6 counters and in every analysis
  error-rate table.
- Client-side (k6) connection contention shows up as its own
  diagnostic, via k6's built-in `http_req_blocked` metric, so a
  throughput plateau at high concurrency can be checked against the
  load generator before it is attributed to server capacity.
- `run-suite.sh` orchestrates a full baseline and concurrency-scan
  suite across clean-slate stack restarts: per-repetition
  target/concurrency shuffling, per-repetition CPU-pinning verification,
  a host/toolchain provenance fingerprint (including a CPU
  governor/frequency snapshot), and a failures log so a broken cell does
  not abort the rest of the suite.
- `warm-up.js` performs JIT/connection-pool warm-up once per stack
  restart, before measurement begins, hitting every target (mock,
  calibration, and all four AI tiers) sequentially in its own dedicated,
  non-overlapping window. Shares `sendTransaction`/`TARGETS` with
  `run-target.js` via `lib/common.js`, so warm-up traffic is tagged and
  classified the same way measured traffic is. Its own latency is
  captured to disk so warm-up convergence can be checked afterward.
  Before the concurrency scan specifically, `run-suite.sh` runs a second
  warm-up pass at `MAX_VUS`, the scan's highest concurrency level, so
  the top of the scan is not a cold start relative to the lower-VUS
  cells.
- `analyze-results.py` produces percentile tables (P50/P95/P99) and
  latency histograms per strategy/tier, significance testing
  (Mann-Whitney U on repetition-level means, Holm-Bonferroni corrected,
  with rank-biserial effect sizes) to avoid pseudoreplication,
  cluster-level bootstrap confidence intervals, between-run
  reproducibility (CoV% across independent repetitions), paired
  error/timeout-rate tables, client-contention diagnostics, a warm-up
  convergence check, and throughput-vs-concurrency figures.
- In-memory H2. Every run starts from a clean slate.

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud)
(anonymized European transactions, September 2013).

- Each tier uses the first `n` of the 28 `V` PCA components (`V1..Vn`)
  plus `Amount`, where `n` is `5`, `10`, `20`, or `28`. Columns stay in
  original order across tiers, so `V10` is a strict superset of `V5`,
  and so on.
- `Amount` is `log1p`-transformed at both train and inference time.
- Highly imbalanced (approximately 0.17% fraud). Trained with SMOTE
  oversampling on the training split, then `XGBClassifier`,
  independently per tier.
- Pretrained models for all four tiers are committed under
  `services/fraud-ml-service/models/`, so `docker compose up` works
  without training anything.
- `creditcard.csv` is not bundled (Kaggle license), so retraining or
  regenerating the shipped models requires placing it at
  `services/fraud-ml-service/training/data/creditcard.csv`, or using
  `--synthetic` for a structural smoke test only.

`training/train_model.py --n-features {5,10,20,28}` trains a single
tier; omitting the flag trains all four in one pass, writing
`models/fraud_model_v{n}.joblib` for each. The Python service loads
whichever tiers are listed in `FEATURE_TIERS` (default `5,10,20,28`) at
startup, and does not start if a listed tier's `.joblib` file is
missing.

## Client Payload Shape

Clients send the full `V1..V28` vector regardless of which tier they
target. Each `/predict/v{n}` endpoint slices the first `n` values it
needs, so the same request body works against any tier without the
client needing to know each model's exact input size. Mock and
calibration ignore `features` entirely.

## Example Request

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

`featureTier` selects which model (`V5`/`V10`/`V20`/`V28`) scores the
request, and is required when `strategy` is `DISTRIBUTED_AI_SYNCHRONOUS`
(ignored for `DISTRIBUTED_MOCK_GATEWAY` and
`DISTRIBUTED_CALIBRATION_ONLY`). `features` must contain at least
`featureTier` values.

Response:

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

`aiCallRoundTripTimeMs` is the full Java-side timing of the call to
`fraud-ml-service`, start to finish. `estimatedNetworkOverheadMs` is
that value minus Python's own `totalPythonExecutionTimeMs`: everything
outside Python's self-reported work, including network transit,
FastAPI/Uvicorn routing, queuing under load, and any wait for a free
connection in the Java-side outbound pool to `fraud-ml-service`
(`python.service.max-connections`, sized and logged at startup; see
Containerization & Hardware). `responseObjectBuildTimeMs` is the time to
assemble the final `ResponseDto` after the AI/DB stages complete.
`executionTimeMs` is the full transaction on the Java side, timestamped
from the earliest point in the WebFlux filter chain
(`RequestTimingWebFilter`) rather than controller entry, so it also
captures Netty/WebFlux routing overhead. `dbWriteTimeMs` is `0.0`
whenever `APP_DB_SAVE_ENABLED=false` (the required setting for
benchmark runs, see [Running](#running)), since no write occurs.

`threadDispatchTimeMs` is the thread-pool queueing/handoff latency
before the worker thread starts running its handler, measured for all
three strategies as dispatch overhead regardless of what the thread
does once scheduled. `computationTimeMs` is
`dataframeConstructionTimeMs` (building the single-row pandas
`DataFrame` the model expects) plus `modelInferenceTimeMs` (the
`model.predict_proba` call itself), split out to separate pandas
overhead from tree-traversal cost. `computeStallMs` is the portion of
`computationTimeMs` during which the worker thread was off-CPU (GIL
contention or OS scheduling) rather than running. For
`DISTRIBUTED_MOCK_GATEWAY` and `DISTRIBUTED_CALIBRATION_ONLY`,
`computationTimeMs` and its three sub-fields
(`dataframeConstructionTimeMs`, `modelInferenceTimeMs`,
`computeStallMs`) are `0.0`, since neither performs computation to
stall on. `serializationResponseTimeMs` and `totalPythonExecutionTimeMs`
are estimates: a response body cannot report the exact cost of
producing itself without being serialized twice, so both derive from a
single serialization pass rather than the literal final one.

`transactionId` must be a UUID, `accountId` must match
`ACC-\d{4,10}`, and both are validated before reaching the AI layer.
Invalid requests receive a `400` with per-field errors.

## Containerization & Hardware

**python-service:** `python:3.11-slim`, port `8000`, cores `0-2`, 3.0 CPU
/ 3G RAM limit (1.0 / 1G reserved). `UVICORN_WORKERS=3` at benchmark
time, set in `docker-compose.yml` (the Dockerfile defaults this to `1`
for standalone container runs outside compose). Each worker process
handles requests concurrently, while `n_jobs=1` plus the BLAS-level
thread-count env vars in the Dockerfile keep any single `predict_proba`
call single-threaded. These are different axes (inter-request versus
intra-model parallelism) with no tension between them on the pinned
3-core range.

**transaction-service:** `eclipse-temurin:21-jdk-alpine` build to
`21-jre-alpine` run, port `8080`, cores `3-5`, 3.0 CPU / 3G RAM limit
(1.0 / 1G reserved). Its outbound WebClient pool to `fraud-ml-service`
is explicitly sized via `python.service.max-connections` (default
`128`, logged at startup). This value must stay at or above the highest
VUS level in `load-testing/run-suite.sh`'s `CONCURRENCY_LEVELS`
(currently `64`), or outbound queueing shows up as inflated
`estimatedNetworkOverheadMs`. `python.service.pending-acquire-timeout-ms`
(default `5000`) bounds how long a request waits for a pooled
connection before failing fast. The valid feature-tier set is fetched
from `fraud-ml-service`'s `/health` endpoint at startup
(`FeatureTierRegistry`); transaction-service retries for up to 60
seconds and fails to start if Python is unreachable. Under
`docker compose up` and `run-suite.sh`, Python's `depends_on: condition:
service_healthy` guarantees this call succeeds on the first attempt.

Requirements:
- **Docker and Docker Compose v2** (`docker compose`). `run-suite.sh`
  checks this automatically per repetition, see
  [CPU pinning verification](#cpu-pinning-verification).
- **6 or more logical cores**. `cpuset` is hardcoded to `0-2`/`3-5`,
  adjust or drop it on smaller machines.
- **Approximately 6GB free RAM** for both services' limits plus
  Docker/k6 overhead.
- **[k6](https://k6.io/docs/get-started/installation/)** installed
  locally, to run the load-testing scripts.
- **Python 3 and `pip install -r analysis/requirements.txt`** (pandas,
  numpy, matplotlib, scipy, statsmodels, tabulate) locally, to run
  `analyze-results.py`.
- No GPU required.

## Running

Full suite (recommended: restarts the stack per repetition, shuffles
order, logs provenance):

```bash
docker compose build
pip install -r analysis/requirements.txt
cd load-testing
./run-suite.sh                                      # baseline + concurrency scan, all reps
python3 ../analysis/analyze-results.py               # tables + figures
```

`run-suite.sh` runs `warm-up.js` at the start of every stack restart
(with an additional max-VUS pass before the concurrency scan), then
drives `run-target.js` per target/concurrency cell across `mock`,
`calibration`, and the four AI tiers, writing one JSON file per cell to
`results/`, plus:

- `run_order_log.txt`: shuffle order per repetition.
- `run_metadata.json`: timestamp, Docker/Compose versions, git commit
  and dirty flag, CPU/RAM, and a CPU governor/frequency snapshot.
- `cpu_pin_check_log.txt`: per-repetition requested-versus-live cpuset
  (see below).
- `warmup_baseline_rep{N}.json`, `warmup_scan_rep{N}.json`, and
  `warmup_scan_maxvus_rep{N}.json`: warm-up request latency, tagged
  `phase=warmup`, used by `analyze-results.py` to check warm-up
  convergence.

Requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`.

### CPU pinning verification

`docker-compose.yml`'s `cpuset` directive states what pinning was
requested. A compose file being accepted does not guarantee the cgroup
driver confined the process to those cores. Each repetition,
`run-suite.sh` reads both sides per container and logs them to
`cpu_pin_check_log.txt`:

- **Requested**: `docker inspect --format '{{.HostConfig.CpusetCpus}}'`,
  the configuration Docker was given at container creation.
- **Live**: `docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective`
  (cgroup v2), falling back to `/sys/fs/cgroup/cpuset/cpuset.cpus` (v1).
  What the kernel actually assigned the running container.

If either side is empty, or the two do not match, that is flagged in
both `cpu_pin_check_log.txt` and `run_failures_log.txt`. Treat that
repetition's results as not core-isolated.

A failed cell (dropped connection, transient error under load) is
logged to `run_failures_log.txt` and skipped, without aborting the rest
of the suite. Stack-level setup failures (containers not coming up,
readiness check timing out) still abort immediately, since every cell
in that repetition would otherwise measure a broken environment. Check
`run_failures_log.txt` after a run and re-run any listed cells manually
before treating the results as complete.

Manual or one-off run:

```bash
docker compose up                                   # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
k6 run --out json=results/results.json your-test.js  # real load test
python3 analysis/analyze-results.py                  # tables + figures
```

`warm-up.js` warms each target (mock, calibration, and all four AI
tiers) sequentially, each in its own dedicated window, so every code
path receives its full request budget before measurement starts.
Tunable via `WARMUP_ITERATIONS_PER_TARGET`, `WARMUP_VUS`,
`WARMUP_MAX_DURATION_S`. Reads `BASE_URL` the same way
`run-target.js`/`lib/common.js` do, falling back to
`http://localhost:8080/api/v1/transactions` if unset.

## Limitations

- **Single-node only.** No multi-region/network-hop simulation.
- **"Network overhead" means Docker bridge-network overhead
  specifically.** `estimatedNetworkOverheadMs` reflects Docker's
  bridge/NAT path between two containers on one host, not a real
  network hop, plus a small serialization-estimation error (see the
  response-fields note above).
- **k6 shares cores with the services under test.** The documented
  minimum host spec is 6 logical cores, exactly matching the two pinned
  service ranges, so k6, the Docker daemon, and the host OS all run on
  those same cores, unpinned. On a minimum-spec host the load generator
  is not isolated from what it measures.
- **No independent verification that k6 was not the bottleneck itself.**
  The client-diagnostics tables (`http_req_blocked`) are a partial
  check, not a guarantee. Read them alongside any throughput plateau at
  high concurrency before attributing it to server capacity.
- **Instrumentation overhead is measured, not eliminated.** The
  `calibration` target bounds the harness's own timing/serialization
  cost as a floor. It does not remove that cost from the AI/mock
  numbers, which still include it.
- **No verification that the two `cpuset` ranges sit on distinct
  physical cores** rather than SMT siblings of each other. Pinning is
  confirmed at the cgroup level, not confirmed as physically isolated.
- **CPU pinning guarantees assume a native Linux Docker host.** On
  Docker Desktop (macOS/Windows), containers run inside a Linux VM, and
  `cpuset` pinning inside that VM has no fixed, documented relationship
  to the physical host's cores.
- **CPU governor/frequency is a single snapshot per suite run**, not a
  per-repetition or per-cell trace. It can flag a run as suspect but
  will not catch thermal throttling that only shows up mid-run under
  sustained load.
- **Synthetic, uniformly-random feature vectors**, not samples from the
  real transaction distribution. The licensed dataset cannot be
  bundled, so `randomFeatures()` draws in a rough PCA-shaped range
  instead.
- **Repetition counts (5 baseline / 5 scan) are not power-justified.**
  Each repetition is a full clean-slate stack restart, so the count is
  a wall-clock-cost tradeoff. 5-vs-5 is also the smallest sample size at
  which a two-sided Mann-Whitney test can reach significance at all
  (p=0.0079 < alpha=0.05), and is used as the floor for both phases.
  Achieved N is always shown alongside each statistical result.
- **Reduced feature space even at the largest tier.** `V1`-`V28` and
  `Amount` form the full PCA set the dataset provides, but the dataset
  itself is a reduced anonymized representation. This benchmarks
  latency, not production-grade fraud detection accuracy.
- **In-memory H2.** Wiped on restart; export `results/` before tearing
  down.
- **`run_metadata.json`, `run_order_log.txt`, `run_failures_log.txt`,
  and `cpu_pin_check_log.txt`** all reflect the last suite run only.
  Each is truncated fresh at the start of `run-suite.sh`, so archive
  them alongside that run's `results/` before starting another.
- **Mock and calibration are latency baselines only**, never real fraud
  checks.
- **`--synthetic` training data** is a smoke test, not a benchmark
  source.
- **`n_jobs=1` verification** confirms the sklearn/XGBoost-level
  parameter reads back as expected. Combined with the BLAS-level env
  vars, it is a strong but not absolute guarantee of single-threaded
  inference on every possible build.
- **6-core CPU pinning** is host-specific. Results are not comparable
  across different core counts/SMT settings without adjusting
  `cpuset`.

## Structure

```
.
├── docker-compose.yml
├── analysis/
│   ├── analyze-results.py        # tables, figures, significance tests
│   └── requirements.txt
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner
│   └── lib/common.js             # shared sendTransaction()/TARGETS + telemetry Trends
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py, calibration.py
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/main/java/.../{controller,service,model,repository,dto,exception,filter}/
```

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock/calibration routing, load testing, and
  telemetry/concurrency work by
  [MuhammadHussain06](https://github.com/MuhammadHussain06),
  integrating and extending both.
