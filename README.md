# Fraud Evaluation Harness — Containerized Testbed

Containerized benchmark that measures the real latency/throughput cost of a
live AI fraud-inference call against a network-equivalent mock baseline.
`docker compose up` reproduces the setup used for the accompanying thesis.

Integrates two services:

- **transaction-service** (Java / Spring Boot, WebFlux + R2DBC) — validates
  and routes transactions, records latency telemetry.
  Originally [`MuhammadHussain06/fraud-eval-harness`](https://github.com/MuhammadHussain06/fraud-eval-harness).
- **fraud-ml-service** (Python / FastAPI) — wraps a trained XGBoost fraud
  classifier.
  Originally [`MianBao-07/fraud-detection-microservice`](https://github.com/MianBao-07/fraud-detection-microservice).

This repo containerizes both, adds a mock baseline endpoint to isolate AI
overhead, pins CPUs per service, and ships k6 load testing plus result
analysis.

## How it works

Every transaction routes through one of two strategies, selected per-request:

- `DISTRIBUTED_AI_SYNCHRONOUS` — scored by a real XGBoost model at a chosen
  feature-count tier: `V5`, `V10`, `V20`, or `V28`.
- `DISTRIBUTED_MOCK_GATEWAY` — scored by a random-value mock with the
  identical request/response shape and network path.

Both paths share the same JVM, network hop, DTOs, and DB write, so the
difference between them isolates model-inference cost from fixed costs
(HTTP, serialization, scheduling). The AI strategy is further split across
four input-size tiers so inference cost can be measured as a function of
feature-vector size, not just as one fixed number.

Clients always send the full `V1..V28` vector regardless of tier — each
`/predict/v{n}` endpoint on the Python side slices the first `n` values it
needs, so one payload shape works against any tier.

Request flow: k6 → `transaction-service` (`POST /api/v1/transactions`) →
`fraud-ml-service` (`POST /predict/v{5,10,20,28}` or `POST /predict/mock`).
Each service runs in its own container, pinned to a disjoint CPU range.

## Dataset

[Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud)
(anonymized European transactions, Sept 2013).

- Each tier uses the first `n` of the 28 `V` PCA components (`V1..Vn`) plus
  `Amount`, in original column order — `V10` is a strict superset of `V5`,
  and so on.
- `Amount` is `log1p`-transformed at train and inference time.
- Highly imbalanced (~0.17% fraud) — trained with SMOTE oversampling on the
  training split, then `XGBClassifier`, independently per tier.
- `creditcard.csv` isn't bundled (Kaggle license). Place it at
  `services/fraud-ml-service/training/data/creditcard.csv` to train for real,
  or pass `--synthetic` for a structural smoke test only.

```bash
# from services/fraud-ml-service/training/
python train_model.py --n-features 10   # single tier
python train_model.py                   # all four tiers (5, 10, 20, 28)
```

Writes `models/fraud_model_v{n}.joblib` for each tier trained. The Python
service loads whichever tiers are listed in `FEATURE_TIERS` (default
`5,10,20,28`) at startup and fails to come up if a listed tier's `.joblib`
file is missing — train before `compose up`.

## Running

```bash
docker compose build
docker compose up --wait                             # waits on python-service health check
k6 run load-testing/warm-up.js                        # JIT / connection-pool warm-up
k6 run --out json=results/results.json your-test.js   # single ad hoc load test
python3 analysis/analyze-results.py                   # percentile tables + histograms
```

For the full reproducible suite used in the thesis (clean stack restart per
repetition, shuffled target/concurrency order, baseline + concurrency-scan
phases):

```bash
cd load-testing
./run-suite.sh
```

Writes one JSON file per (target, concurrency, rep) cell to `../results/`,
plus `run_order_log.txt`. Then run `analyze-results.py` against that
directory (`--results-dir` / `--output-dir` are overridable, both default to
`results/` and `analysis/output/`).

`run-suite.sh` requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`
(already set) so DB writes don't skew the measured latency.

### Requirements

- **6+ logical cores** — `cpuset` is hardcoded to `0-2` / `3-5` in
  `docker-compose.yml`; adjust or remove it on smaller machines. Results
  aren't comparable across different core counts/SMT settings without
  matching `cpuset`.
- **~6GB free RAM** for both services' resource limits plus Docker/k6
  overhead.
- **Docker Compose v2** (`docker compose`) — verify `deploy.resources`
  limits actually apply with `docker inspect` before trusting a run.
- No GPU needed.

## Example request

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

- `strategy` — `DISTRIBUTED_AI_SYNCHRONOUS` or `DISTRIBUTED_MOCK_GATEWAY`.
- `featureTier` — one of `5`/`10`/`20`/`28`; required for
  `DISTRIBUTED_AI_SYNCHRONOUS`, ignored for `DISTRIBUTED_MOCK_GATEWAY`.
  `features` must contain at least `featureTier` values.
- `transactionId` must be a UUID, `accountId` must match `ACC-\d{4,10}` —
  both validated before reaching the AI layer; invalid requests return `400`
  with per-field errors.

### Example response

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
  "dbWriteTimeMs": 0.0,
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

- `executionTimeMs` — total time inside `transaction-service`, start to finish.
- `aiCallRoundTripTimeMs` — full WebClient round trip to `fraud-ml-service`.
- `estimatedNetworkOverheadMs` — `aiCallRoundTripTimeMs` minus
  `pythonTelemetry.totalPythonExecutionTimeMs`; the portion of the round
  trip not accounted for by Python-side execution.
- `dbWriteTimeMs` — `0.0` when `APP_DB_SAVE_ENABLED=false`.
- `pythonTelemetry.computationTimeMs` is the sum of
  `dataframeConstructionTimeMs` (building the single-row pandas `DataFrame`
  the model expects) and `modelInferenceTimeMs` (the `predict_proba` call
  itself), split out to separate pandas overhead from tree-traversal cost.
  For `DISTRIBUTED_MOCK_GATEWAY` responses, both sub-fields are `0.0`.

## Structure

```
.
├── docker-compose.yml
├── analysis/
│   ├── analyze-results.py     # percentile tables, histograms, Mann-Whitney U tests
│   └── requirements.txt
├── load-testing/
│   ├── run-suite.sh           # full baseline + concurrency-scan reproduction suite
│   ├── run-target.js          # single (target, concurrency, rep) cell
│   ├── warm-up.js             # JIT / connection-pool warm-up
│   └── lib/common.js          # shared k6 request/metric helpers
├── results/                   # k6 JSON output (created at run time)
└── services/
    ├── fraud-ml-service/              # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py                # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py                # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py               # FEATURE_TIERS, MODEL_DIR, FRAUD_THRESHOLD
    │   │   ├── schemas.py
    │   │   ├── responses.py            # shared response/telemetry builder
    │   │   └── routers/                # predict.py (POST /predict/v{n}), mock.py
    │   ├── models/fraud_model_v{5,10,20,28}.joblib
    │   └── training/train_model.py     # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/            # Java Spring Boot orchestrator
        └── src/main/java/.../{controller,service,model,repository,dto,exception}/
```

## Containerization

| | image | port | cores | limit | reserved |
|---|---|---|---|---|---|
| **python-service** | `python:3.11-slim` | `8000` | `0-2` | 3.0 CPU / 3G RAM | 1.0 CPU / 1G RAM |
| **transaction-service** | `eclipse-temurin:21-jdk-alpine` → `21-jre-alpine` | `8080` | `3-5` | 3.0 CPU / 3G RAM | 1.0 CPU / 1G RAM |

`python-service` runs `UVICORN_WORKERS=3` (overridable via env) and gates
readiness on `GET /health`; `transaction-service` waits on that health check
via `depends_on`.

## Limitations

- **Single-node only** — no multi-region/network-hop simulation.
- **Reduced feature space even at the largest tier** — `V1`–`V28` + `Amount`
  is the full PCA set the dataset provides, but the dataset itself is a
  reduced anonymized representation. This benchmarks latency, not
  production-grade fraud detection accuracy.
- **In-memory H2** — wiped on restart; export `results/` before tearing down.
- **Mock endpoint** is a latency baseline only, never a real fraud check.
- **`--synthetic` training data** is a smoke test, not a benchmark source.
- **Resource limits** depend on Compose version — verify before trusting results.
- **6-core CPU pinning** is host-specific; not comparable across different
  core counts/SMT settings without adjusting `cpuset`.

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock routing, load testing, and telemetry/concurrency fixes integrate and extend both.
