import http from 'k6/http';
import { sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export const options = {
  duration: '20s',
  vus: 5, // Light load to trigger JIT compilation
};

// One target per real endpoint: mock baseline + each feature-count tier.
// featureTier: null means "mock" (tier is ignored server-side for mock).
const TARGETS = [
  { strategy: 'DISTRIBUTED_MOCK_GATEWAY', featureTier: null },
  { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 5 },
  { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 10 },
  { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 20 },
  { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 28 },
];

const parsingTime = new Trend('python_parsing_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const dataframeConstructionTime = new Trend('python_dataframe_construction_time_ms', true);
const modelInferenceTime = new Trend('python_model_inference_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

// Client always sends the full V1..V28 vector; each /predict/v{n} endpoint
// slices the first n values it needs, so one payload shape works for every tier.
function randomFeatures(n) {
  const arr = [];
  for (let i = 0; i < n; i++) {
    arr.push(Math.random() * 4 - 2); // roughly PCA-component-shaped range
  }
  return arr;
}

export default function () {
  const url = 'http://localhost:8080/api/v1/transactions';
  const target = TARGETS[__ITER % TARGETS.length];
  const tierLabel = target.featureTier !== null ? String(target.featureTier) : 'mock';

  const body = {
    transactionId: uuidv4(),
    accountId: "ACC-1000",
    amount: 100.0,
    transactionType: "PURCHASE",
    features: randomFeatures(28),
    strategy: target.strategy,
  };
  if (target.featureTier !== null) {
    body.featureTier = target.featureTier;
  }

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { strategy: target.strategy, tier: tierLabel },
  };

  const res = http.post(url, JSON.stringify(body), params);

  if (res.status === 200) {
    const responseBody = JSON.parse(res.body);
    const telemetry = responseBody.pythonTelemetry;
    if (telemetry) {
      const tags = { strategy: target.strategy, tier: tierLabel };
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

  sleep(0.5);
}