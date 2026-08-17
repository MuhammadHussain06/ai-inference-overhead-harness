import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080/api/v1/transactions';

// Maps TARGET env vars / filenames ('mock' | '5' | '10' | '20' | '28') to tier config.
export const TARGETS = {
  mock: { strategy: 'DISTRIBUTED_MOCK_GATEWAY', featureTier: null },
  '5': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 5 },
  '10': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 10 },
  '20': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 20 },
  '28': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 28 },
};

// Overrides default k6 `http_req_failed` handling to mark non-200 responses as failures,
// ensuring application-level errors (4xx/5xx) are accurately tracked alongside network drops.
http.setResponseCallback(http.expectedStatuses(200));

const parsingTime = new Trend('python_parsing_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const dataframeConstructionTime = new Trend('python_dataframe_construction_time_ms', true);
const modelInferenceTime = new Trend('python_model_inference_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

// Distinguishes application-level HTTP errors (non-200 responses like 400s/500s) from network-level
// timeouts (no response received, status 0) to report structural outages separately from application rejections.
const requestSuccess = new Rate('request_success');
const requestHttpError = new Counter('request_http_error');
const requestTimeoutError = new Counter('request_timeout_error');

// Sends a static V1..V28 payload; /predict/v{n} endpoints slice required features.
export function randomFeatures(n) {
  const arr = [];
  for (let i = 0; i < n; i++) {
    arr.push(Math.random() * 4 - 2); // roughly PCA-component-shaped range
  }
  return arr;
}

// Executes a target transaction and records k6 metrics alongside
// nested Python telemetry (via Trend.add). Attaches extraTags
// (e.g., vus/phase) for analyze-results.py grouping.
export function sendTransaction(target, extraTags) {
  const tierLabel = target.featureTier !== null ? String(target.featureTier) : 'mock';

  const body = {
    transactionId: uuidv4(),
    accountId: 'ACC-1000',
    amount: 100.0,
    transactionType: 'PURCHASE',
    features: randomFeatures(28),
    strategy: target.strategy,
  };
  if (target.featureTier !== null) {
    body.featureTier = target.featureTier;
  }

  const tags = Object.assign({ strategy: target.strategy, tier: tierLabel }, extraTags || {});
  const params = { headers: { 'Content-Type': 'application/json' }, tags };

  const res = http.post(BASE_URL, JSON.stringify(body), params);

  // Explicit check for k6's built-in `checks` metric to align default k6 pass/fail output
// with the custom analysis script metrics, independent of Rate and Counter counters.
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, tags);
  requestSuccess.add(ok, tags);

  if (res.status === 200) {
    const responseBody = JSON.parse(res.body);
    const telemetry = responseBody.pythonTelemetry;
    if (telemetry) {
      parsingTime.add(telemetry.parsingRequestTimeMs, tags);
      computationTime.add(telemetry.computationTimeMs, tags);
      dataframeConstructionTime.add(telemetry.dataframeConstructionTimeMs, tags);
      modelInferenceTime.add(telemetry.modelInferenceTimeMs, tags);
      serializationTime.add(telemetry.serializationResponseTimeMs, tags);
      totalPythonTime.add(telemetry.totalPythonExecutionTimeMs, tags);
    }
  } else if (res.status === 0) {
// Handles network-level drops (connection reset, DNS/TLS failure, or client timeout)
    // where no response was received, using res.error and res.error_code for classification.
    requestTimeoutError.add(1, tags);
    console.error(`Timeout/network error [${target.strategy}/${tierLabel}]: ` +
        `error_code=${res.error_code} error=${res.error}`);
  } else {
// Tracks non-200 application responses (e.g., 400s/500s) as a distinct category,
// separating explicit application rejections from network-level timeouts.
    requestHttpError.add(1, tags);
    console.error(`HTTP error [${target.strategy}/${tierLabel}]: ${res.status} ${res.body}`);
  }

  return res;
}