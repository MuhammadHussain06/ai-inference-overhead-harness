import { sendTransaction, TARGETS } from './lib/common.js';

// Single-target load generator executed once per (target, concurrency, rep) cell.
// Targets a fixed total request count (ITERATIONS) per cell, split evenly
// across VUs.
//
// Env Vars:
//   TARGET   : Target endpoint key ('mock' | '5' | '10' | '20' | '28') [Required]
//   VUS      : Concurrent virtual users [Required]
//   ITERATIONS : Target total requests across all VUs [Required]
//   PHASE    : Experiment tag (e.g., 'baseline', 'scan') [Optional]
//   REP      : Session repetition index for variance tagging [Default: '1']
//   BASE_URL : API endpoint override [Default: http://localhost:8080/api/v1/transactions]

const targetKey = __ENV.TARGET;
if (!targetKey || !(targetKey in TARGETS)) {
  throw new Error(`TARGET env var must be one of ${Object.keys(TARGETS).join(', ')}, got: ${targetKey}`);
}
const target = TARGETS[targetKey];

const vus = parseInt(__ENV.VUS || '1', 10);
const iterations = parseInt(__ENV.ITERATIONS || '500', 10);
const phase = __ENV.PHASE || 'unspecified';
const rep = __ENV.REP || '1';

const iterationsPerVu = Math.max(1, Math.ceil(iterations / vus));

export const options = {
  scenarios: {
    run: {
      executor: 'per-vu-iterations',
      vus: vus,
      iterations: iterationsPerVu,
      maxDuration: '10m',
    },
  },
};


export default function () {
  sendTransaction(target, { vus: String(vus), phase, rep });
}
