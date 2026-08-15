# Fraud Evaluation Harness — Containerized Testbed

Containerized benchmarking testbed that measures the real latency/throughput
cost of a live AI fraud-inference call vs. a network-equivalent mock
baseline. One `docker compose up` reproduces the load-test results used in
the accompanying thesis.

Integrates two previously separate services:

- **transaction-service** (Java / Spring Boot) — [`MuhammadHussain06/fraud-eval-harness`](https://github.com/MuhammadHussain06/fraud-eval-harness) — reactive REST API, validates and routes transactions, records latency telemetry.
- **fraud-ml-service** (Python / FastAPI) — [`MianBao-07/fraud-detection-microservice`](https://github.com/MianBao-07/fraud-detection-microservice) — wraps a trained XGBoost fraud classifier.

This repo containerizes both, adds a mock baseline endpoint for isolating
AI overhead, pins CPUs per service, and ships k6 load testing + result
analysis.

---

## Idea

Every transaction routes through one of two strategies:

- `DISTRIBUTED_AI_SYNCHRONOUS` — scored by a real XGBoost model at a chosen
  feature-count tier (see below).
- `DISTRIBUTED_MOCK_GATEWAY` — scored by a random-value mock with the
  identical request/response shape and network path.

Since both paths share the same JVM, network hop, DTOs, and DB write, the
*difference* between them isolates model-inference cost from fixed costs
(HTTP, serialization, scheduling). Within the AI strategy, the model itself
is swappable across four input-size tiers — `V5`, `V10`, `V20`, `V28` — so
inference cost can also be measured as a function of feature-vector size,
not just as a single fixed number.

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
        ▼
fraud-ml-service (Python, FastAPI / Uvicorn, XGBoost registry)
```

Each service runs in its own container, pinned to a disjoint CPU range, so
they never contend for the same cores during a run.

## Features

- Dual-strategy routing, switchable per-request via `strategy` field.
- Four feature-count tiers for the AI strategy (`5`/`10`/`20`/`28`), selected
  per-request via `featureTier` and routed to `/predict/v{tier}` — each tier
  is its own XGBoost model, loaded once at startup and held in memory
  alongside the others.
- Stage-by-stage latency: parsing, network, DB-write, serialization (Java)
  + parsing, computation (split into DataFrame construction and model
  inference), serialization (Python), nested in one response.
- Reactive Java stack end-to-end (WebFlux + R2DBC).
- CPU-pinned, resource-limited containers.
- `run-suite.sh`: orchestrates a full baseline + concurrency-scan suite
  across clean-slate stack restarts, with per-rep target/concurrency
  shuffling and a captured host/toolchain provenance fingerprint.
- `warm-up.js`: JIT/connection-pool warm-up, run once per stack restart
  before measurement begins.
- `analyze-results.py`: percentile tables (P50/P95/P99) + latency histogram,
  split by strategy.
- In-memory H2 — every run starts from a clean slate.

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud)
(anonymized European transactions, Sept 2013).

- Each tier uses the first `n` of the 28 `V` PCA components (`V1..Vn`) +
  `Amount`, where `n` is `5`, `10`, `20`, or `28` — columns stay in original
  order across tiers, so `V10` is a strict superset of `V5`, and so on.
- `Amount` is `log1p`-transformed at train and inference time.
- Highly imbalanced (~0.17% fraud) — trained with SMOTE oversampling on the
  training split, then `XGBClassifier`, independently per tier.
- `creditcard.csv` isn't bundled (Kaggle license) — place it at
  `services/fraud-ml-service/training/data/creditcard.csv` to train, or use
  `--synthetic` for a structural smoke test only.

`training/train_model.py --n-features {5,10,20,28}` trains a single tier;
omitting the flag trains all four in one pass, writing
`models/fraud_model_v{n}.joblib` for each. The Python service loads
whichever tiers are listed in `FEATURE_TIERS` (default `5,10,20,28`) at
startup — a run will fail to come up if a listed tier's `.joblib` file is
missing, so train before compose-ing up.

## Client Payload Shape

Clients send the full `V1..V28` vector regardless of which tier they're
targeting — each `/predict/v{n}` endpoint slices the first `n` values it
needs, so the same request body works against any tier without the client
needing to know each model's exact input size.

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
request and is required when `strategy` is `DISTRIBUTED_AI_SYNCHRONOUS`
(ignored for `DISTRIBUTED_MOCK_GATEWAY`); `features` must contain at least
`featureTier` values.

Response:

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "riskScore": 0.9123,
  "transactionStatus": "FLAGGED",
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10,
  "executionTimeMs": 14.7,
  "requestParsingTimeMs": 0.03,
  "networkCommunicationTimeMs": 8.9,
  "dbWriteTimeMs": 2.1,
  "responseSerializationTimeMs": 0.4,
  "pythonTelemetry": {
    "parsingRequestTimeMs": 0.21,
    "computationTimeMs": 1.85,
    "dataframeConstructionTimeMs": 1.23,
    "modelInferenceTimeMs": 0.62,
    "serializationResponseTimeMs": 0.09,
    "totalPythonExecutionTimeMs": 2.31
  }
}
```

`computationTimeMs` is the sum of `dataframeConstructionTimeMs` (building the
single-row pandas `DataFrame` the model expects) and `modelInferenceTimeMs`
(the `model.predict_proba` call itself) — split out to separate pandas
overhead from actual tree-traversal cost. For `DISTRIBUTED_MOCK_GATEWAY`
responses both sub-fields are `0.0`, since the mock does neither.

`transactionId` must be a UUID, `accountId` must match `ACC-\d{4,10}` —
both validated before reaching the AI layer; invalid requests return `400`
with per-field errors.

## Containerization & Hardware

**python-service:** `python:3.11-slim` · port `8000` · cores `0-2` · 3.0 CPU / 3G RAM limit (1.0 / 1G reserved)

**transaction-service:** `eclipse-temurin:21-jdk-alpine` build → `21-jre-alpine` run · port `8080` · cores `3-5` · 3.0 CPU / 3G RAM limit (1.0 / 1G reserved)

Requirements:
- **6+ logical cores** — `cpuset` is hardcoded to `0-2`/`3-5`; adjust or
  remove it on smaller machines.
- **~6GB free RAM** for both services' limits plus Docker/k6 overhead.
- **Docker Compose v2** (`docker compose`) — verify `deploy.resources`
  limits actually apply with `docker inspect` before trusting a run.
- No GPU needed.

## Running

Full suite (recommended — restarts the stack per rep, shuffles order, logs
provenance):

```bash
docker compose build
cd load-testing
./run-suite.sh                                      # baseline + concurrency scan, all reps
python3 ../analysis/analyze-results.py               # percentile tables + histogram
```

`run-suite.sh` runs `warm-up.js` once at the start of every stack restart,
then drives `run-target.js` per target/concurrency cell, writing one JSON
file per cell to `results/`, plus `run_order_log.txt` (shuffle order per
rep) and `run_metadata.json` (timestamp, Docker/Compose versions, git
commit + dirty flag, CPU/RAM — so results stay traceable to the environment
that produced them). Requires `APP_DB_SAVE_ENABLED=false` in
`docker-compose.yml`.

Manual / one-off run:

```bash
docker compose up                                   # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
k6 run --out json=results/results.json your-test.js  # real load test
python analysis/analyze-results.py                   # percentile tables + histogram
```

`warm-up.js` warms each target (mock + all four AI tiers) sequentially,
each in its own dedicated time window, so every code path gets its full
request budget before measurement starts. Tunable via
`WARMUP_ITERATIONS_PER_TARGET`, `WARMUP_VUS`, `WARMUP_MAX_DURATION_S` env
vars. Telemetry metrics are recorded separately, in `run-target.js` (via
the shared `sendTransaction` helper in `lib/common.js`) during the actual
measured runs.

## Limitations

- **Single-node only** — no multi-region/network-hop simulation.
- **Reduced feature space even at the largest tier** (`V1`–`V28` + `Amount`
  is the full PCA set the dataset provides, but the dataset itself is a
  reduced anonymized representation) — benchmarks latency, not
  production-grade fraud detection accuracy.
- **In-memory H2** — wiped on restart; export `results/` before tearing down.
- **`run_metadata.json`** records the CPU/RAM/Docker/git fingerprint of the
  *last* suite run only — it's overwritten each time `run-suite.sh` runs,
  so archive it alongside that run's `results/` before starting another.
- **Mock endpoint** is a latency baseline only, never a real fraud check.
- **`--synthetic` training data** is a smoke test, not a benchmark source.
- **Resource limits** depend on Compose version — verify before trusting results.
- **6-core CPU pinning** is host-specific; results aren't comparable across
  different core counts/SMT settings without adjusting `cpuset`.
  
## Structure

```
.
├── docker-compose.yml
├── analysis/analyze-results.py
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner
│   └── lib/common.js             # shared sendTransaction() + telemetry Trends
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint + TimingMiddleware
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py
    │   ├── models/fraud_model_v{5,10,20,28}.joblib
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/main/java/.../{controller,service,model,repository,dto,exception}/
```

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock routing, load testing, and telemetry/concurrency fixes integrate and extend both.
