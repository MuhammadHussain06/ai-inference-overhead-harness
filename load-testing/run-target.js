import { sendTransaction, TARGETS } from './lib/common.js';

// Single-target k6 script executed per (target, concurrency, rep) cell.
//
// Env Vars:
//   TARGET            : Endpoint key ('mock' | 'calibration' | '5' | '10' | '20' | '28') [Required]
//   VUS               : Concurrent virtual users [Required]
//   ITERATIONS_PER_VU : Requests per VU; used by the concurrency scan to keep
//                       the per-VU sample count constant as VUS varies. Total
//                       N therefore grows with VUS (100 at VUS=1, 6400 at
//                       VUS=64) -- intentional, since higher-VUS cells need
//                       more samples to resolve tail percentiles under
//                       contention. VUS=1 here is intentionally thin; the
//                       baseline (E1) phase already covers VUS=1 densely. [Optional]
//   ITERATIONS        : Total request budget divided across VUs; used by the
//                       baseline (VUS=1) cells [Optional, default: 500]
//   PHASE             : Experiment phase tag ('baseline', 'scan', 'ablation') [Optional]
//   REP               : Repetition index for session variance tagging [Default: '1']
//   ARM               : Ablation mechanism name, e.g. 'thread_limiter' [Optional]
//   ARM_VALUE         : Value under test for ARM, e.g. '64' [Optional]
//   BASE_URL          : Target API endpoint [Default: http://localhost:8080/api/v1/transactions]

const targetKey = __ENV.TARGET;
if (!targetKey || !(targetKey in TARGETS)) {
  throw new Error(`TARGET env var must be one of ${Object.keys(TARGETS).join(', ')}, got: ${targetKey}`);
}
const target = TARGETS[targetKey];

const vus = parseInt(__ENV.VUS || '1', 10);
const phase = __ENV.PHASE || 'unspecified';
const rep = __ENV.REP || '1';

let iterationsPerVu;
if (__ENV.ITERATIONS_PER_VU) {
  iterationsPerVu = Math.max(1, parseInt(__ENV.ITERATIONS_PER_VU, 10));
} else {
  // Total-request budget divided across VUs. Used for baseline (VUS=1)
  // cells, where per-VU iteration count is equivalent; ITERATIONS_PER_VU
  // is preferred for the concurrency scan, where VUS varies per cell.
  const iterations = parseInt(__ENV.ITERATIONS || '500', 10);
  iterationsPerVu = Math.max(1, Math.ceil(iterations / vus));
}

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


const extraTags = { vus: String(vus), phase, rep };
if (__ENV.ARM) extraTags.arm = __ENV.ARM;
if (__ENV.ARM_VALUE) extraTags.arm_value = __ENV.ARM_VALUE;

export default function () {
  sendTransaction(target, extraTags);
}