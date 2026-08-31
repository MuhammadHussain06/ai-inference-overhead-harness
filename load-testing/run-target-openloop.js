import { sendTransaction, TARGETS } from './lib/common.js';

// Manual, standalone open-loop (constant-arrival-rate) check for coordinated
// omission at the top concurrency cells (32/64). Not invoked by run-suite.sh
// and not a replacement for run-target.js's closed-loop (per-vu-iterations) model.
//
// Env Vars:
//   TARGET             : 'mock' | 'calibration' | '5' | '10' | '20' | '28' [Required]
//   RATE               : Requests per TIME_UNIT to hold constant [Required]
//   TIME_UNIT          : k6 duration string [Optional, default: '1s']
//   DURATION           : How long to hold the rate [Optional, default: '2m']
//   PRE_ALLOCATED_VUS  : VUs reserved up front to sustain RATE [Optional, default: 64]
//   MAX_VUS            : Ceiling k6 can grow to if responses slow down [Optional, default: 128]
//   PHASE              : Experiment phase tag [Default: 'openloop-check']
//   REP                : Repetition index [Default: '1']
//   BASE_URL           : Target API endpoint [Default: http://localhost:8080/api/v1/transactions]
//
// If k6 exhausts MAX_VUS it logs dropped_iterations -- the server can't sustain
// that rate. That's a real finding; don't raise MAX_VUS just to hide it.

const targetKey = __ENV.TARGET;
if (!targetKey || !(targetKey in TARGETS)) {
    throw new Error(`TARGET env var must be one of ${Object.keys(TARGETS).join(', ')}, got: ${targetKey}`);
}
const target = TARGETS[targetKey];

const rate = parseInt(__ENV.RATE, 10);
if (!rate || rate < 1) {
    throw new Error('RATE env var must be a positive integer (requests per TIME_UNIT).');
}

const timeUnit = __ENV.TIME_UNIT || '1s';
const duration = __ENV.DURATION || '2m';
const preAllocatedVUs = parseInt(__ENV.PRE_ALLOCATED_VUS || '64', 10);
const maxVUs = parseInt(__ENV.MAX_VUS || '128', 10);
const phase = __ENV.PHASE || 'openloop-check';
const rep = __ENV.REP || '1';

export const options = {
    scenarios: {
        run: {
            executor: 'constant-arrival-rate',
            rate: rate,
            timeUnit: timeUnit,
            duration: duration,
            preAllocatedVUs: preAllocatedVUs,
            maxVUs: maxVUs,
        },
    },
};

export default function () {
    sendTransaction(target, { rate: String(rate), phase, rep });
}