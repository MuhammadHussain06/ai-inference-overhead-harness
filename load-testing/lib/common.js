import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080/api/v1/transactions';

// Maps TARGET env vars / filenames ('mock' | 'calibration' | '5' | '10' | '20' | '28') to tier config.
// label is explicit so calibration (featureTier: null) can't collide with mock.
export const TARGETS = {
  mock: { strategy: 'DISTRIBUTED_MOCK_GATEWAY', featureTier: null, label: 'mock' },
  calibration: { strategy: 'DISTRIBUTED_CALIBRATION_ONLY', featureTier: null, label: 'calibration' },
  '5': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 5, label: '5' },
  '10': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 10, label: '10' },
  '20': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 20, label: '20' },
  '28': { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 28, label: '28' },
};

// Overrides default k6 `http_req_failed` handling to mark non-200 responses as failures,
// ensuring application-level errors (4xx/5xx) are accurately tracked alongside network drops.
http.setResponseCallback(http.expectedStatuses(200));

const parsingTime = new Trend('python_parsing_time_ms', true);
const threadDispatchTime = new Trend('python_thread_dispatch_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const dataframeConstructionTime = new Trend('python_dataframe_construction_time_ms', true);
const modelInferenceTime = new Trend('python_model_inference_time_ms', true);
// Server-side thread off-CPU time during computation (GIL/scheduling stalls),
// distinct from threadDispatchTime (pre-execution queueing).
const computeStallTime = new Trend('python_compute_stall_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

// Java-side estimate: aiCallRoundTripTimeMs minus Python's own totalPythonExecutionTimeMs.
const javaEstimatedNetworkOverhead = new Trend('java_estimated_network_overhead_ms', true);

// Distinguishes application-level HTTP errors (non-200 responses like 400s/500s) from network-level
// timeouts (no response received, status 0) to report structural outages separately from application rejections.
const requestSuccess = new Rate('request_success');
const requestHttpError = new Counter('request_http_error');
const requestTimeoutError = new Counter('request_timeout_error');

// Generates a fixed-length (28) randomized payload; /predict/v{n} endpoints slice required features.
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
  const tierLabel = target.label;

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

  // Explicit check for k6's built-in `checks` metric, to align default k6
  // pass/fail output with the custom Rate/Counter metrics above.
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, tags);
  requestSuccess.add(ok, tags);

  if (res.status === 200) {
    const responseBody = JSON.parse(res.body);
    const telemetry = responseBody.pythonTelemetry;
    if (telemetry) {
      parsingTime.add(telemetry.parsingRequestTimeMs, tags);
      threadDispatchTime.add(telemetry.threadDispatchTimeMs, tags);
      computationTime.add(telemetry.computationTimeMs, tags);
      dataframeConstructionTime.add(telemetry.dataframeConstructionTimeMs, tags);
      modelInferenceTime.add(telemetry.modelInferenceTimeMs, tags);
      computeStallTime.add(telemetry.computeStallMs, tags);
      serializationTime.add(telemetry.serializationResponseTimeMs, tags);
      totalPythonTime.add(telemetry.totalPythonExecutionTimeMs, tags);
    }
    if (responseBody.estimatedNetworkOverheadMs !== undefined) {
      javaEstimatedNetworkOverhead.add(responseBody.estimatedNetworkOverheadMs, tags);
    }
  } else if (res.status === 0) {
    // status === 0: no response was received (connection reset, DNS/TLS
    // failure, or client timeout). res.error/res.error_code are logged
    // for diagnostics only; classification itself is by status code.
    requestTimeoutError.add(1, tags);
    console.error(`Timeout/network error [${target.strategy}/${tierLabel}]: ` +
        `error_code=${res.error_code} error=${res.error}`);
  } else {
    // Non-200 application response (e.g., 400s/500s), tracked separately
    // from network-level timeouts above.
    requestHttpError.add(1, tags);
    console.error(`HTTP error [${target.strategy}/${tierLabel}]: ${res.status} ${res.body}`);
  }

  return res;
}