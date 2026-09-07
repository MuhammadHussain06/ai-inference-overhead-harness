import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

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

// Only 200 is a valid outcome here, so k6's default (any 2xx/3xx) would let a cell
// where every request failed still look healthy.
http.setResponseCallback(http.expectedStatuses(200));

const parsingTime = new Trend('python_parsing_time_ms', true);
const threadDispatchTime = new Trend('python_thread_dispatch_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const dataframeConstructionTime = new Trend('python_dataframe_construction_time_ms', true);
const modelInferenceTime = new Trend('python_model_inference_time_ms', true);
// Off-CPU time within computation (GIL/scheduling stalls). Distinct from
// threadDispatchTime, which is pre-execution queueing, and already contained in
// computationTime rather than additive to it.
const computeStallTime = new Trend('python_compute_stall_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

// Java-side estimate: aiCallRoundTripTimeMs minus Python's own totalPythonExecutionTimeMs.
const javaEstimatedNetworkOverhead = new Trend('java_estimated_network_overhead_ms', true);
// Java-side end-to-end. Recorded so http_req_duration minus this figure -- Netty
// ingress, response encoding and the client hop -- is computable from the dataset.
const javaExecutionTime = new Trend('java_execution_time_ms', true);

// Application-level HTTP errors (a non-200 response) are structurally different from
// network-level timeouts (status 0, no response at all): the second censors the cell's
// latency distribution, the first does not.
const requestSuccess = new Rate('request_success');
const requestHttpError = new Counter('request_http_error');
const requestTimeoutError = new Counter('request_timeout_error');

// Vendored rather than imported from jslib.k6.io, so a cell cannot fail on a CDN
// lookup partway through a multi-hour suite.
function uuidv4() {
  let out = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
    } else if (i === 14) {
      out += '4';
    } else if (i === 19) {
      out += ((Math.random() * 4) | 8).toString(16);
    } else {
      out += ((Math.random() * 16) | 0).toString(16);
    }
  }
  return out;
}

// Always 28 values regardless of tier, so the request body is the same size for every
// condition and payload size cannot explain a tier difference. /predict/v{n} slices.
export function randomFeatures(n) {
  const arr = [];
  for (let i = 0; i < n; i++) {
    arr.push(Math.random() * 4 - 2); // roughly PCA-component-shaped range
  }
  return arr;
}

// Executes a target transaction and records k6 metrics alongside the nested Python
// telemetry. extraTags (vus/phase/rep/arm) are analyze-results.py's grouping keys.
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

  // Aligns k6's built-in `checks` output with the custom Rate/Counter metrics above.
  const ok = check(res, { 'status is 200': (r) => r.status === 200 }, tags);
  requestSuccess.add(ok, tags);

  if (res.status === 200) {
    let responseBody = null;
    try {
      responseBody = JSON.parse(res.body);
    } catch (e) {
      console.error(`Unparseable 200 body [${target.strategy}/${tierLabel}]: ${e}`);
    }
    // Telemetry is recorded only on this branch, so the Python Trends hold
    // successful requests by construction and need no status filter downstream.
    if (responseBody) {
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
      } else {
        console.error(`200 response carried no pythonTelemetry [${target.strategy}/${tierLabel}]`);
      }
      if (responseBody.estimatedNetworkOverheadMs !== undefined) {
        javaEstimatedNetworkOverhead.add(responseBody.estimatedNetworkOverheadMs, tags);
      }
      if (responseBody.executionTimeMs !== undefined) {
        javaExecutionTime.add(responseBody.executionTimeMs, tags);
      }
    }
  } else if (res.status === 0) {
    // No response received: connection reset, DNS/TLS failure, or client timeout.
    // res.error/res.error_code are logged for diagnostics; classification is by status.
    requestTimeoutError.add(1, tags);
    console.error(`Timeout/network error [${target.strategy}/${tierLabel}]: ` +
        `error_code=${res.error_code} error=${res.error}`);
  } else {
    requestHttpError.add(1, tags);
    console.error(`HTTP error [${target.strategy}/${tierLabel}]: ${res.status} ${res.body}`);
  }

  return res;
}