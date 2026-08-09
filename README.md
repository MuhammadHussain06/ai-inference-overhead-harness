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

- `DISTRIBUTED_AI_SYNCHRONOUS` — scored by the real XGBoost model.
- `DISTRIBUTED_MOCK_GATEWAY` — scored by a random-value mock with the
  identical request/response shape and network path.

Since both paths share the same JVM, network hop, DTOs, and DB write, the
*difference* between them isolates model-inference cost from fixed costs
(HTTP, serialization, scheduling).

## Architecture

```
k6 load generator
        │
        ▼
transaction-service (Java, Spring Boot 3 / WebFlux, Netty, H2 via R2DBC)
        │
        │  WebClient (non-blocking)
        │    POST /predict       → real inference
        │    POST /predict/mock  → baseline
        ▼
fraud-ml-service (Python, FastAPI / Uvicorn, XGBoost)
```

Each service runs in its own container, pinned to a disjoint CPU range, so
they never contend for the same cores during a run.

## Features

- Dual-strategy routing, switchable per-request via `strategy` field.
- Stage-by-stage latency: parsing, network, DB-write, serialization (Java)
  + parsing, computation, serialization (Python), nested in one response.
- Reactive Java stack end-to-end (WebFlux + R2DBC).
- CPU-pinned, resource-limited containers.
- k6 script that alternates strategies and captures Python telemetry as
  k6 metrics.
- `analyze-results.py`: percentile tables (P50/P95/P99) + latency histogram,
  split by strategy.
- In-memory H2 — every run starts from a clean slate.

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud)
(anonymized European transactions, Sept 2013).

- Uses `V1`–`V5` (of 28 PCA components) + `Amount`, kept small on purpose.
- `Amount` is `log1p`-transformed at train and inference time.
- Highly imbalanced (~0.17% fraud) — trained with SMOTE oversampling on the
  training split, then `XGBClassifier`.
- `creditcard.csv` isn't bundled (Kaggle license) — place it at
  `services/fraud-ml-service/training/data/creditcard.csv` to retrain, or
  use `--synthetic` for a structural smoke test only.

The shipped `models/fraud_model.joblib` is pre-trained — no dataset needed
just to run the benchmark.

## Methodological Changes From the Original Services

1. **Accurate parsing telemetry.** `parsingRequestTimeMs` used to be timed
   after Pydantic already parsed the request, so it always read ~0. Fixed
   with a Starlette middleware that timestamps before parsing.
2. **Concurrency-symmetric endpoints.** Mock was `async def`, real was sync
   `def` — different Uvicorn scheduling (event loop vs. threadpool), which
   would skew concurrency comparisons. Both are now sync `def`.
3. **Shared response builder.** Telemetry/response assembly was duplicated
   across routers; consolidated into `build_response()` in `app/responses.py`.
4. **Build reproducibility.** `mvnw`/`mvnw.cmd` lost their executable bit in
   transit; Dockerfile now `chmod +x`'s them before building.

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
  "v1": 2.8,
  "v2": -1.2,
  "v3": 0.5,
  "v4": 1.8,
  "v5": -0.8,
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS"
}
```

Response:

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "riskScore": 0.9123,
  "transactionStatus": "FLAGGED",
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "executionTimeMs": 14.7,
  "requestParsingTimeMs": 0.03,
  "networkCommunicationTimeMs": 8.9,
  "dbWriteTimeMs": 2.1,
  "responseSerializationTimeMs": 0.4,
  "pythonTelemetry": {
    "parsingRequestTimeMs": 0.21,
    "computationTimeMs": 1.85,
    "serializationResponseTimeMs": 0.09,
    "totalPythonExecutionTimeMs": 2.31
  }
}
```

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

```bash
docker compose build
docker compose up                                   # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
k6 run --out json=results/results.json your-test.js  # real load test
python analysis/analyze-results.py                   # percentile tables + histogram
```

`warm-up.js` alternates strategies per iteration and tags requests so
metrics split cleanly — use it as the base for larger concurrency sweeps.

## Limitations

- **Single-node only** — no multi-region/network-hop simulation.
- **Reduced feature set** (`V1`–`V5` + `Amount`) — benchmarks latency, not
  production-grade fraud detection accuracy.
- **In-memory H2** — wiped on restart; export `results/` before tearing down.
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
├── load-testing/warm-up.js
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint + TimingMiddleware
    │   │   ├── model.py             # model load + inference
    │   │   ├── config.py
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py, mock.py
    │   ├── models/fraud_model.joblib
    │   └── training/train_model.py
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/main/java/.../{controller,service,model,repository,dto,exception}/
```

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock routing, load testing, and telemetry/concurrency fixes integrate and extend both.
