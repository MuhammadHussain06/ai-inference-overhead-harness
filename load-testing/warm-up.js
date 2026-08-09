import http from 'k6/http';
import { sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

export const options = {
  duration: '20s',
  vus: 5, // Light load to trigger JIT compilation
};

const STRATEGIES = ['DISTRIBUTED_MOCK_GATEWAY', 'DISTRIBUTED_AI_SYNCHRONOUS'];

const parsingTime = new Trend('python_parsing_time_ms', true);
const computationTime = new Trend('python_computation_time_ms', true);
const serializationTime = new Trend('python_serialization_time_ms', true);
const totalPythonTime = new Trend('python_total_time_ms', true);

export default function () {
  const url = 'http://localhost:8080/api/v1/transactions';
  const strategy = STRATEGIES[__ITER % STRATEGIES.length];

  const payload = JSON.stringify({
    transactionId: uuidv4(),
    accountId: "ACC-1000",
    amount: 100.0,
    transactionType: "PURCHASE",
    v1: 0.1, v2: 0.2, v3: 0.3, v4: 0.4, v5: 0.5,
    strategy: strategy
  });

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { strategy: strategy },
  };

  const res = http.post(url, payload, params);

  if (res.status === 200) {
    const body = JSON.parse(res.body);
    const telemetry = body.pythonTelemetry;
    if (telemetry) {
      const tags = { strategy: strategy };
      parsingTime.add(telemetry.parsingRequestTimeMs, tags);
      computationTime.add(telemetry.computationTimeMs, tags);
      serializationTime.add(telemetry.serializationResponseTimeMs, tags);
      totalPythonTime.add(telemetry.totalPythonExecutionTimeMs, tags);
    }
  }

  sleep(0.5);
}