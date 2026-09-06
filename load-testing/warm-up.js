import { sendTransaction, TARGETS } from './lib/common.js';

// Sequentially warms JIT tiers, connection pools, and OS/network buffers past compilation thresholds.
// 3000 iterations ensure tail stability; 60s timeout derives fixed target slot length without extra latency overhead.

const ITERATIONS_PER_TARGET = parseInt(__ENV.WARMUP_ITERATIONS_PER_TARGET || '3000', 10);
const VUS = parseInt(__ENV.WARMUP_VUS || '5', 10);
const MAX_DURATION_S = parseInt(__ENV.WARMUP_MAX_DURATION_S || '60', 10);
const ITERATIONS_PER_VU = Math.max(1, Math.ceil(ITERATIONS_PER_TARGET / VUS));

// Adds buffer beyond MAX_DURATION_S to prevent target VU execution overlap between warmup windows.
const SLOT_S = MAX_DURATION_S + 5;

const ORDER = (__ENV.WARMUP_TARGETS || 'mock calibration 5 10 20 28').trim().split(/\s+/);

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