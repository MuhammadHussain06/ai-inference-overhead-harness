import { sendTransaction, TARGETS } from './lib/common.js';

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
//   BASE_URL                     : Target API endpoint [Default: http://localhost:8080/api/v1/transactions]

const ITERATIONS_PER_TARGET = parseInt(__ENV.WARMUP_ITERATIONS_PER_TARGET || '1500', 10);
const VUS = parseInt(__ENV.WARMUP_VUS || '5', 10);
const MAX_DURATION_S = parseInt(__ENV.WARMUP_MAX_DURATION_S || '60', 10);
const ITERATIONS_PER_VU = Math.max(1, Math.ceil(ITERATIONS_PER_TARGET / VUS));

// Small buffer beyond MAX_DURATION_S so a target that runs right up to
// its ceiling still fully vacates its window before the next target's
// VUs spin up (guarantees strict non-overlap regardless of pacing).
const SLOT_S = MAX_DURATION_S + 5;

const ORDER = ['mock', 'calibration', '5', '10', '20', '28'];

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

function warm(key) {
  sendTransaction(TARGETS[key], { phase: 'warmup' });
}


export function warm_mock() { warm('mock'); }
export function warm_calibration() { warm('calibration'); }
export function warm_5() { warm('5'); }
export function warm_10() { warm('10'); }
export function warm_20() { warm('20'); }
export function warm_28() { warm('28'); }