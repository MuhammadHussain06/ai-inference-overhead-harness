import http from 'k6/http';
import { Trend } from 'k6/metrics';
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

const parsingTime = new Trend('python_parsing_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const dataframeConstructionTime = new Trend('python_dataframe_construction_time_ms', true);
const modelInferenceTime = new Trend('python_model_inference_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

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
  } else {
    console.error(`Request failed [${target.strategy}/${tierLabel}]: ${res.status} ${res.body}`);
  }

  return res;
}
