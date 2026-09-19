import { sendTransaction, TARGETS } from './lib/common.js';

// Warms JIT tiers, connection pools, and OS/network buffers past compilation
// thresholds. Defaults to constant-vus: every VU runs for a fixed wall-clock
// duration at flat concurrency, with gracefulStop disabled so no VU lingers
// past that duration finishing one last iteration while others have already
// stopped -- that kind of staggered drain would thin concurrency during the
// grace window and read as fast, "converged" latency to a tail-window
// convergence check when it is really just fewer VUs contending. Passing
// WARMUP_ITERATIONS_PER_TARGET selects a fixed-count per-vu-iterations pass
// instead, for callers (smoke tests) that want a fast, deterministic run and
// don't check the tail.

const VUS = parseInt(__ENV.WARMUP_VUS || '5', 10);
const MAX_DURATION_S = parseInt(__ENV.WARMUP_MAX_DURATION_S || '60', 10);
const ORDER = (__ENV.WARMUP_TARGETS || 'mock calibration 5 10 20 28').trim().split(/\s+/);

// Same convention as run-target.js.
const rep = __ENV.REP || '1';

const ITERATIONS_PER_TARGET_RAW = __ENV.WARMUP_ITERATIONS_PER_TARGET;
const USE_ITERATIONS = ITERATIONS_PER_TARGET_RAW !== undefined && ITERATIONS_PER_TARGET_RAW !== '';

let SLOT_S;
let scenarioFor;

if (USE_ITERATIONS) {
    const ITERATIONS_PER_TARGET = parseInt(ITERATIONS_PER_TARGET_RAW, 10);
    const ITERATIONS_PER_VU = Math.max(1, Math.ceil(ITERATIONS_PER_TARGET / VUS));
    // Adds buffer beyond MAX_DURATION_S to prevent target VU execution overlap between warmup windows.
    SLOT_S = MAX_DURATION_S + 5;
    scenarioFor = (key, i) => ({
        executor: 'per-vu-iterations',
        vus: VUS,
        iterations: ITERATIONS_PER_VU,
        maxDuration: `${MAX_DURATION_S}s`,
        startTime: `${i * SLOT_S}s`,
        exec: `warm_${key}`,
    });
} else {
    const DURATION_S = parseInt(__ENV.WARMUP_DURATION_S || '15', 10);
    // gracefulStop: '0s' interrupts whatever's still in flight at DURATION_S
    // instead of letting each VU wind down on its own; SLOT_S keeps its buffer
    // regardless so the next target's scenario still can't overlap this one's.
    SLOT_S = DURATION_S + 10;
    scenarioFor = (key, i) => ({
        executor: 'constant-vus',
        vus: VUS,
        duration: `${DURATION_S}s`,
        gracefulStop: '0s',
        startTime: `${i * SLOT_S}s`,
        exec: `warm_${key}`,
    });
}

export const options = {
    scenarios: Object.fromEntries(ORDER.map((key, i) => [`warm_${key}`, scenarioFor(key, i)])),
};

function warm(key) {
    sendTransaction(TARGETS[key], { phase: 'warmup', rep });
}


export function warm_mock() { warm('mock'); }
export function warm_calibration() { warm('calibration'); }
export function warm_5() { warm('5'); }
export function warm_10() { warm('10'); }
export function warm_20() { warm('20'); }
export function warm_28() { warm('28'); }