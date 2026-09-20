import { sendTransaction, TARGETS } from './lib/common.js';

// Standalone open-loop check on the closed-loop scan's coordinated omission, run by
// hand at the top concurrency cells. constant-arrival-rate fires on a fixed schedule
// regardless of response time; k6's own dropped_iterations rises once maxVUs can no
// longer sustain RATE, marking the point where the arrival rate exceeded capacity.

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