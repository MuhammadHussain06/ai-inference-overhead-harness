import http from 'k6/http';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// Warms JIT tiers, connection pools, and OS/network buffers prior to measurement.
//
// Key Execution Details:
//   - Dedicated Windows : Targets are warmed sequentially (not interleaved) to ensure
//                         every code path reaches the required invocation volume.
//   - Unthrottled Cadence: Matches evaluation phases (back-to-back requests, no sleep)
//                         to reflect true post-warmup load shapes.
//   - Fixed Request Budget: Sized well past HotSpot JIT compilation thresholds to ensure
//                         predictable repetition length without adaptive timing variances.
//
// Env Vars (Optional):
//   WARMUP_ITERATIONS_PER_TARGET : Requests sent per target window [Default: 1500]
//   WARMUP_VUS                   : Concurrent VUs per target window [Default: 5]
//   WARMUP_MAX_DURATION_S        : Hard per-target timeout ceiling (seconds) [Default: 60]

const ITERATIONS_PER_TARGET = parseInt(__ENV.WARMUP_ITERATIONS_PER_TARGET || '1500', 10);
const VUS = parseInt(__ENV.WARMUP_VUS || '5', 10);
const MAX_DURATION_S = parseInt(__ENV.WARMUP_MAX_DURATION_S || '60', 10);
const ITERATIONS_PER_VU = Math.max(1, Math.ceil(ITERATIONS_PER_TARGET / VUS));

// Small buffer beyond MAX_DURATION_S so a target that runs right up to
// its ceiling still fully vacates its window before the next target's
// VUs spin up (guarantees strict non-overlap regardless of pacing).
const SLOT_S = MAX_DURATION_S + 5;

const TARGETS = {
  mock: { strategy: 'DISTRIBUTED_MOCK_GATEWAY', featureTier: null },
  v5: { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 5 },
  v10: { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 10 },
  v20: { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 20 },
  v28: { strategy: 'DISTRIBUTED_AI_SYNCHRONOUS', featureTier: 28 },
};
const ORDER = ['mock', 'v5', 'v10', 'v20', 'v28'];

export const options = {
  scenarios: Object.fromEntries(
      ORDER.map((key, i) => [
        `warm_${key}`,
        {
          executor: 'per-vu-iterations',
          vus: VUS,
          iterations: ITERATIONS_PER_VU,
          maxDuration: `${MAX_DURATION_S}s`,
          startTime: `${i * SLOT_S}s`,
          exec: `warm_${key}`,
        },
      ])
  ),
};

// Client always sends the full V1..V28 vector; each /predict/v{n} endpoint
// slices the first n values it needs, so one payload shape works for every tier.
function randomFeatures(n) {
  const arr = [];
  for (let i = 0; i < n; i++) {
    arr.push(Math.random() * 4 - 2); // roughly PCA-component-shaped range
  }
  return arr;
}

function sendWarmupRequest(key) {
  const target = TARGETS[key];

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

  const params = {
    headers: { 'Content-Type': 'application/json' },
    tags: { strategy: target.strategy, tier: key },
  };

  const res = http.post('http://localhost:8080/api/v1/transactions', JSON.stringify(body), params);

  if (res.status !== 200) {
    console.error(`Warm-up request failed [${target.strategy}/${key}]: ${res.status} ${res.body}`);
  }
}

// One exported function per target, bound to its own scenario above --
// k6 scenarios select behavior via `exec`, so each target's dedicated
// window runs its own isolated warm-up function.
export function warm_mock() { sendWarmupRequest('mock'); }
export function warm_v5() { sendWarmupRequest('v5'); }
export function warm_v10() { sendWarmupRequest('v10'); }
export function warm_v20() { sendWarmupRequest('v20'); }
export function warm_v28() { sendWarmupRequest('v28'); }