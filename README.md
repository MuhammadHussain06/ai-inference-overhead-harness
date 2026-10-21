# AI Inference Overhead Harness

A containerized testbed that measures the **latency and throughput cost of a live AI fraud-inference call**, against a path-equivalent mock and a zero-work calibration floor.

```bash
./setup.sh                        # once per machine
docker compose build              # build both service images
sudo ./prepare-host.sh            # before every run: the CPU power state (turbo off)
./load-testing/run-all.sh         # suite, open-loop and composition checks, ablation, then both analyses
```

---

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Running](#running)
- [Outputs](#outputs)
- [Measurement controls](#measurement-controls)
- [Experimental design rationale](#experimental-design-rationale)
- [Threats to validity](#threats-to-validity)
- [Cross-host comparison](#cross-host-comparison)
- [Diagnostics](#diagnostics)
- [Tests](#tests)
- [Fault-injection guard verification](#fault-injection-guard-verification)
- [Reference](#reference): API, dataset and models, containers and hardware
- [Structure](#structure)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)

---

## Overview

Every transaction is scored by one of three arms, selected per request by its `strategy` field. All three share the same JVM, DTOs and inter-service hop: Java's WebClient calls `fraud-ml-service` over HTTP across the Docker bridge in every case.

| Arm (`strategy`) | Target | Work in Python | Purpose |
|---|---|---|---|
| `DISTRIBUTED_AI_SYNCHRONOUS` | `5`, `10`, `20`, `28` | XGBoost model for the feature-count tier in `featureTier` (`V5`/`V10`/`V20`/`V28`), routed to `/predict/v{tier}` | Actual inference cost |
| `DISTRIBUTED_MOCK_GATEWAY` | `mock` | One random draw; same request/response shape and path | Path-equivalent baseline |
| `DISTRIBUTED_CALIBRATION_ONLY` | `calibration` | None, not even a random draw | Instrumentation floor |

Terms used throughout:

- **Tier:** the model's input width: 5, 10, 20 or 28 `V` features, plus `Amount`.
- **Arm:** `calibration`, `mock` or AI, the request's `strategy`. The ablation's four arms are a separate use of the word: the mechanisms it sweeps, named by its `arm` field.
- **Target:** an arm at a tier, six in all: `calibration`, `mock`, `5`, `10`, `20` and `28`.
- **Cell:** one k6 load test against one target at one concurrency level. **VUs** are k6 virtual users, the concurrency; the harness's `VUS` variable sets them.
- **Repetition (rep):** one independent pass over an experiment's cells, from a restarted stack.
- **Experiments:** E1, the baseline at VUS 1; E2, the concurrency scan; the ablation; and the open-loop check.
- **Guards:** automated checks that abort a run on a wrong environment ([Measurement controls](#measurement-controls)).

Latency is attributed by subtraction, since each pair of arms differs in one layer:

- `calibration` traverses every layer the AI path does (parsing, thread dispatch, serialization, the inter-service hop) with no work behind it, bounding the framework and transport floor.
- **Mock − calibration** ≈ the cost of one random draw.
- **AI tier − calibration** ≈ DataFrame construction plus model inference.
- `test_api.py` asserts all three arms emit structurally identical telemetry, the precondition for the subtraction.

Each tier is its own XGBoost model, loaded once at startup and held in memory. DB persistence is off for every benchmark run (`APP_DB_SAVE_ENABLED=false`), so writes never enter the measured path, and H2 is in memory, so every run starts clean.

### Research questions

| | Question | Answered by |
|---|---|---|
| **RQ1** | In a synchronous microservice call, how does end-to-end latency decompose across model inference, DataFrame construction, thread dispatch, framework overhead, the inter-service hop and the client-side remainder? | E1 baseline (`run-suite.sh`); tables 1 to 3, figures 1 and 2 |
| **RQ2** | How does that decomposition shift with model input width (tier) and request concurrency? | E1 across tiers, E2 concurrency scan; tables 4 to 6, figures 3 to 5 |
| **RQ3** | Which mechanism drives the thread-dispatch cost that grows with request concurrency: thread-limiter capacity, available cores, or process count (GIL)? | [Ablation](#ablation-rq3) (`run-ablation.sh`, `analyze-ablation.py`), four arms |
| **RQ4** | Do the ratios behind RQ1 to RQ3 reproduce across repetitions and hosts? | Per-ratio equivalence tests between runs, after an environment gate ([Cross-host comparison](#cross-host-comparison)) |

### Scope

**Answers**, for a synchronous, single-node microservice call with one row per request, measured with turbo off:

- how much of end-to-end latency is model compute versus everything else (the inter-service hop, framework, serialization, queueing);
- how that ratio shifts with feature tier and concurrency;
- whether those ratios reproduce across runs and hosts.

**Does not answer** (see [Threats to validity](#threats-to-validity)):

- batched or dynamically batched inference: every call is one row in, one prediction out;
- multi-model or multi-tenant serving, or GPU inference;
- multi-region or multi-hop network latency;
- latency at turbo clock speeds;
- fraud-detection accuracy, which is never measured. The model is a stand-in workload, chosen for its four-tier feature-count structure.

---

## Architecture

```
k6 load generator
        │
        ▼
transaction-service (Java, Spring Boot 3 / WebFlux, Netty, H2 via R2DBC)
        │
        │  WebClient (non-blocking)
        │    POST /predict/v{5,10,20,28}  → real inference, tier-selected
        │    POST /predict/mock           → baseline
        │    POST /predict/calibrate      → zero-work floor
        ▼
fraud-ml-service (Python, FastAPI / Uvicorn, XGBoost registry)
```

- The Java stack is reactive end to end (WebFlux, R2DBC).
- Each service runs in its own container on a disjoint set of physical cores, so they never contend for cores during a run ([Containers and hardware](#containers-and-hardware)).

---

## Requirements

- Docker and Docker Compose v2 (`docker compose`). Core pinning assumes a native Linux Docker host ([Threats to validity](#threats-to-validity)).
- 16 logical CPUs. The default `cpuset` values span CPUs 0 to 15 and assume SMT siblings are *adjacent* logical CPUs, so each service owns whole physical cores. On a host that enumerates siblings differently (e.g. Intel's `N` / `N+8` layout), `verify_smt_isolation()` aborts before any container starts.
  - `load-testing/recommend-cpusets.sh` picks values for this host: it reads the topology, uses performance cores only on a hybrid CPU, and prints `export` lines for `PYTHON_CPUSET`, `JAVA_CPUSET`, `K6_CPUSET`, their matching CPU quotas (`*_CPUS`) and the ablation's narrow and wide cpusets, pre-checked against the suite's cpuset guard. It only recommends: review the output, `export` it, then run.
  - To inspect the topology by hand: `cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list`.
- About 7 GiB of free RAM, the sum of the three containers' memory limits. No GPU.
- `sudo`, for `prepare-host.sh` before every run.
- Python 3 on the host. The harness scripts use it for tier verification, the warm-up gate, result filtering and the samplers; the analysis needs `analysis/requirements.txt` (pandas, numpy, matplotlib, scipy, statsmodels, tabulate, jinja2), which `setup.sh` installs into `analysis/venv/`.
  - `jinja2` backs the LaTeX table export; without it `.tex` output fails.
  - The file pins floors, not ceilings: recent CPython (3.13+) needs recent wheels, and old exact pins can fail to build from source on a newer compiler toolchain.
- k6 runs in its own container for every harness script and is pulled on first use. A host-installed `k6` is needed only for a [manual run](#manual-or-one-off-run).

---

## Running

### 1. Setup (once per machine)

```bash
./setup.sh
docker compose build    # again after any change under services/
```

`setup.sh` is safe to re-run. It:

- writes `.env` with your UID and GID, which `docker-compose.yml` applies to all three services (`user: ${HOST_UID:-1000}:${HOST_GID:-1000}`). Neither service image sets a non-root `USER` and the `k6` image runs as its own fixed UID, so without it bind-mounted output is owned by root or another UID and `k6` writes fail;
- pre-creates `results/gc-logs/`, the GC log mount of a hand-started stack, so it is host-owned rather than created by `docker compose up` as root;
- creates `analysis/venv/` with `analysis/requirements.txt` installed (Ubuntu 24.04+ refuses a bare `pip install` against the system Python).

### 2. Prepare the host (before every run)

```bash
sudo ./prepare-host.sh              # turbo off, the default every harness script requires
sudo TURBO=on ./prepare-host.sh     # for runs started with REQUIRED_TURBO_OVERRIDE=on
```

A cell's latency depends on the CPU clock, which follows settings outside this project's configuration: turbo, the governor, the package power limits set by the firmware, and `thermald`, which adjusts those limits on its own. `prepare-host.sh`:

- sets the `performance` governor on every CPU;
- sets turbo through whichever control the cpufreq driver offers (`intel_pstate/no_turbo`, the global `cpufreq/boost` switch, or per-policy boost);
- stops `thermald`;
- prints the resulting state, and exits non-zero if the host is still unprepared (e.g. on battery).

None of this survives a reboot. Every harness script checks the state before touching the stack or the results directory, and refuses to start when:

- the host is on battery;
- turbo differs from `REQUIRED_TURBO_OVERRIDE` (default `off`);
- the governor is not `performance`;
- `thermald` is running.

A control the host does not expose, such as cpufreq in most VMs or a battery on a desktop, is recorded as `unexposed` rather than required. The state is re-checked throughout the run ([Measurement controls](#measurement-controls)), and `run-openloop.sh` and `run-predict-composition.sh` also refuse a state that differs from the one their suite run recorded.

### 3. Smoke test (before the full suite)

```bash
sudo ./prepare-host.sh
docker compose up -d
cd load-testing
./run-smoke-test.sh
```

Runs every path the full design depends on at small scale, catching a structural problem (bad config, broken tag, mislabeled tier) in minutes:

- a suite slice: 2 targets, 2 concurrency levels, 2 reps, reduced iteration counts;
- a deliberately unsustainable 20s open-loop cell at `RATE=5000` through `run-openloop.sh` (one rep, fixed-iteration warm-up), to confirm `dropped_iterations` is detected;
- a one-rep composition check (`COMPOSITION_N=50`), asserting that `predict_composition.json` is written with schema 2;
- a two-cell slice of the ablation's `cpuset` arm, whose values are cpuset strings rather than integers;
- **both** analysis scripts.

It ends with a checklist for the two run directories it names:

- failures logs empty, including `openloop_failures_log.txt` and `composition_failures_log.txt`; cpu-pin logs clean, including the `smt_check` lines and the open-loop's `recorded_setting` lines;
- env trace logs with `cell_start`/`cell_end`, `cell_freq` and `thermal_check` lines for every cell; both calibration logs filled;
- `power_state` in both metadata files as `prepare-host.sh` set it;
- `placement` lines for every cell, not `placement_unavailable`;
- a nonzero `dropped_iterations` count on the printed `[+] smoke-openloop:` line;
- both cpuset values in `table_ablation_decomposition`, ordered by logical-CPU count.

Expected on a smoke run:

- Table 7 omits the overload cell (`phase=smoke-openloop` is excluded by design); the script checks that cell's file directly, then deletes it. It deletes the 50-call `predict_composition.json` too, so table 9 is skipped.
- Both table 0s list every target as `fewer than three windows`: the gate needs three windows of at least 500 requests, and the slice sends about 20 per target.
- The ablation tables carry no meaningful statistics at 2 reps; they only need to render.
- The smoke runs are ordinary runs: they archive this machine's previous suite and ablation runs, and `analysis/output/` then holds only the two smoke runs.

A clean smoke test shows the pipeline works, not that any rep count is sufficient. Re-run it after any fix until it passes.

### 4. Everything in one run

`run-all.sh` runs `run-suite.sh`, then `run-openloop.sh` and `run-predict-composition.sh` against that suite run, `run-ablation.sh`, then `analyze-results.py` and `analyze-ablation.py` on the two runs it produced.

- It checks the power state before the first step (unless it starts at `analysis`) and records the state, or the refusal, in `run-all.log`.
- Each step's output goes to `results/logs/run-all_<UTC timestamp>/`, with one line per step in `run-all.log`.
- A failed suite stops the chain. A failed open-loop or composition check is reported and the chain continues; a failed ablation skips its own analysis. The exit status is non-zero if any step failed. Before the composition step it stops the stack the suite or open-loop step left up, since the check refuses to share the host with it.
- At the defaults, the open-loop check adds about 45 to 60 minutes (7 reps of a restart, guards, two gated warm-up passes and two 2-minute cells with 10s cooldowns) and the composition check about 5 minutes (7 reps of about 25s of timing plus container start and a 10s cooldown).
- Steps, in order: `suite`, `openloop`, `composition`, `ablation`, `analysis`. `START_AT=openloop`, `composition`, `ablation` or `analysis` resumes at that step against this host's latest runs.

The full design takes most of a day. To run it detached, with the machine kept awake:

```bash
sudo ./prepare-host.sh                          # before launch: sudo cannot prompt once detached
nohup systemd-inhibit --what=sleep:idle:handle-lid-switch --who=harness --why="benchmark run" \
  ./load-testing/run-all.sh >/dev/null 2>&1 & disown
sleep 3; tail -F "$(ls -td results/logs/run-all_*/ | head -1)run-all.log"
```

### 5. Individual steps

#### Full suite

```bash
cd load-testing
./run-suite.sh                                                 # baseline + concurrency scan, all reps
../analysis/venv/bin/python3 ../analysis/analyze-results.py    # tables + figures
```

Requires `APP_DB_SAVE_ENABLED=false` in `docker-compose.yml`. Each invocation writes one run directory under `results/` ([Outputs](#outputs)). Defaults: targets `mock`, `calibration` and the four AI tiers; 7 baseline reps; 7 scan reps; concurrency levels 1/2/4/8/16/32/64; 10s cooldown between cells.

1. **E1 baseline**, per rep: restart the stack, run the convergence-gated warm-up with the pin and tier checks around it ([Measurement controls](#measurement-controls)), then run each target at VUS 1 in shuffled order.
2. **Calibration pass**, once: derive each target's duration-targeted iteration counts for VUS 8 and above ([Experimental design rationale](#experimental-design-rationale)).
3. **E2 scan**, per rep: the same preparation plus a second warm-up pass at the maximum VUS, then run `run-target.js` for every target and concurrency cell, targets and levels shuffled independently.

During every measured cell, `lib/placement.py` records which python-service worker holds each inbound connection and `lib/cpufreq_sampler.py` records each service's CPU clock.

#### Ablation (RQ3)

```bash
cd load-testing
./run-ablation.sh                                              # 11 cells x 7 reps
../analysis/venv/bin/python3 ../analysis/analyze-ablation.py   # ablation tables + figure
```

A separate script. It holds the workload at `TARGET=28`, `VUS=64` and sweeps one mechanism at a time, the others at their control values:

| Arm | Values | Control |
|---|---|---|
| `thread_limiter` | 40 / 64 / 128 tokens | 40 |
| `cpuset` | narrow / control / wide (2 / 6 / 8 logical CPUs by default) | 6 CPUs |
| `workers` | 1 / 2 / 3 uvicorn processes | 3 |
| `workers_token_matched` | 1 worker at 40 tokens vs. 3 workers at 13 tokens each | none; a matched pair |

- **`workers_token_matched`:** the limiter is per process, so a worker-count change otherwise moves GIL count and aggregate token capacity together. This arm holds aggregate capacity constant, to the nearest integer.
- **Duration-targeted cells:** each cell's iteration count is derived once, in a calibration pass before the reps that restarts the stack at that cell's configuration and warms it up as its reps will; every rep of the cell runs that count.
- **Controls:** every cell runs on a stack restarted at its own configuration, in an order shuffled per rep, with the suite's warm-up gate, pin, JVM and tier verification, power-state checks, thermal and clock telemetry, and abort-on-invalid behavior. Connection placement is not sampled.
- **Planned comparison** (`table_ablation_control_vs_extreme`): per arm, the control value recorded in `ablation_run_metadata.json` against the sweep value farthest from it (by logical CPUs for a cpuset), the arm's largest manipulation. The control sits at an end of the sweep for `thread_limiter` and `workers`, and inside it for `cpuset`, where 2 CPUs is farther from the 6-CPU control than 8. `workers_token_matched` compares its two values directly.

#### Open-loop validity check

The suite's concurrency scan is closed-loop. `run-target-openloop.js` runs the same target under k6's `constant-arrival-rate` executor, firing on a fixed schedule regardless of response time, the standard mitigation for coordinated omission. `run-all.sh` runs it after the suite.

```bash
cd load-testing
./run-openloop.sh                                   # this host's latest suite run
./run-openloop.sh ../results/suite_<host>_<timestamp>
```

- **Rates:** fractions (`OPENLOOP_FRACTIONS`, default `1.0 0.8`) of the target's closed-loop throughput at the run's highest scan concurrency (`lib/openloop_rates.py`, table 4's convention): at the plateau, where an open arrival process meets a saturated service, and below it. `OPENLOOP_RATES` sets explicit requests per second instead.
- **Cells:** `OPENLOOP_DURATION` (`2m`) each, with `OPENLOOP_PRE_ALLOCATED_VUS` (64) and `OPENLOOP_MAX_VUS` (128). `OPENLOOP_REPS` (7, the suite's scan reps) repetitions, each running every rate once in a shuffled order, tagged `REP=<n>` and written as `openloop_<target>_rate<R>_rep<n>.json.gz`. `OPENLOOP_TARGET` (28) and `OPENLOOP_PHASE` are overridable.
- **Controls:** the suite's, from the same code (`lib/suite-stack.sh`). The stack starts on the cpusets, CPU quotas, uvicorn worker count and thread-limiter tokens the suite run recorded in `run_metadata.json`, exported so every compose call resolves them; a missing value is refused, and a resolved value or `JAVA_TOOL_OPTIONS` that differs from the record aborts. At startup the topology and whole-core cpuset guards run on those cpusets. Each rep then does what a scan rep does: a full restart, the CPU-pinning, JVM-flag and tier checks (including the numeric thread environment on `/health`), the convergence-gated warm-up at the suite's parameters (5 VUs, then the suite run's maximum VUS), the post-warm-up `n_jobs` and JVM live-thread checks, and the suite's cooldown (`OPENLOOP_COOLDOWN_S`, default the recorded `cooldown_s`). Every cell runs after a thermal check, between power-state checks against the state the suite run recorded, under the clock and connection-placement samplers, followed by the OOM check.
- **Failures:** an abort writes one line, tagged with target and rep, to `openloop_failures_log.txt`, never to `run_failures_log.txt`, so a failed check marks table 7 rather than rejecting the suite run. A new invocation first moves its target's earlier cells, warm-up files and failure lines to `archive/openloop_<timestamp>/`, so reps of two invocations never mix.
- **Pool size:** Java's outbound pool is 2x `OPENLOOP_MAX_VUS` (256), the rule every harness script applies to its own peak VUS; it is the one setting not taken from the suite run, whose pool is sized for its 64 VUS.
- **`dropped_iterations`:** k6 emits it when `MAX_VUS` cannot sustain the rate, i.e. the service cannot absorb that arrival rate.
- **Analysis:** when `openloop_*` files are present, `analyze-results.py` adds table 7 and figure 7, comparing open-loop P95/P99 with the closed-loop scan at the top two scanned concurrency levels for the same tier; without them the step is skipped and the rest of the analysis is unaffected. The rep is the unit on both sides: P95 and P99 within each rep, reported as the median across reps with the min-max range and the rep count, beside table 4's pooled P95 with its cluster-bootstrap CI; dropped iterations are summed over reps, with the largest single-rep count. Figure 7 shows the per-rep P99 spread. Table 7 is grouped by tier *and* `RATE`, so cells at different rates are never pooled, keeps a row for a cell with no HTTP 200, reads older single-rep files as one rep, and always excludes the smoke test's `phase=smoke-openloop` cell.

#### predict_proba composition check

The model-inference field times the whole `predict_proba` call, so the harness's telemetry cannot tell input conversion from tree traversal. `run-predict-composition.sh` measures the split in-process, and `run-all.sh` runs it after the open-loop check. No stack is started, and the script refuses to run while any python-service, transaction-service or k6 container is running.

```bash
cd load-testing
./run-predict-composition.sh                                   # this host's latest suite run
./run-predict-composition.sh ../results/suite_<host>_<timestamp>
```

- **Where:** `lib/predict_composition.py` runs in a one-off container of the already-built python-service image (`docker compose run --rm --no-deps`), so it uses the locked pandas and XGBoost (2.1.1). The container gets the suite run's recorded Python cpuset and CPU quota; from inside, the script verifies its CPU affinity against the cpuset and the cgroup's CPU limit (v2 `cpu.max`, or v1 CFS quota over period) against the quota, aborting on a mismatch and recording `unverifiable` where the cgroup exposes no quota file. A run whose metadata records no Python cpuset or quota is refused.
- **Repetitions:** `COMPOSITION_REPS` (7), each in a fresh container, the analogue of the suite's restart, with the tier order shuffled per rep, a thermal check before it, the suite run's recorded power state checked before and after it, and the suite's cooldown (`COMPOSITION_COOLDOWN_S`, default the recorded `cooldown_s`) between reps. Each rep writes `predict_composition_reps/rep<n>.json`; after the last, the host merges them into `predict_composition.json` (schema 2), which therefore exists only for a complete set of reps. An abort writes one line, tagged with the rep, to `composition_failures_log.txt`, never to `run_failures_log.txt`.
- **What:** per tier, the request DataFrame exactly as `model.py` builds it, from a fixed feature vector in `common.js`'s range and amount 100.0, with the model loaded and pinned to `n_jobs=1` as the service does. After a warm-up (`COMPOSITION_WARMUP`, 200), `COMPOSITION_N` (2000) calls each, in rotating order so drift hits all equally, of three streams:
  - **total:** `predict_proba(df)`, as the service calls it. At this XGBoost version it takes the in-place prediction path and builds no `DMatrix`;
  - **traversal:** the booster on a pre-built `DMatrix` of the same frame: tree evaluation plus the booster call, without pandas conversion or feature-name validation. This is the DMatrix baseline;
  - **in-place:** `inplace_predict` on a pre-built float32 array, the dense form of the path `predict_proba` takes. It keeps that path's own per-call setup, so it is a lower-bound baseline and a cross-check on traversal.

  Conversion is total minus traversal, between medians; table 9 also reports the share against the in-place baseline.
- **Analysis:** when `predict_composition.json` is present, `analyze-results.py` adds table 9; without it, a one-line notice and the rest of the analysis is unaffected. Per tier, each rep's medians and shares come first, then the median across reps with the min-max range, the rep count and N per rep. A schema-1 file (one container, before v1.3.0) reads as one rep. Entries in `composition_failures_log.txt` are printed and noted in table 9's caption; they never reject the suite run.
- **Across hosts:** tables 7 and 9 are per run. The host-variance analyses do not compare either, and both are outside the pre-registered metric set ([What is compared](#what-is-compared)); compare runs' tables side by side.

#### Manual or one-off run

```bash
docker compose up                                    # waits for python health check
k6 run load-testing/warm-up.js                       # JIT warm-up
TARGET=28 VUS=8 PHASE=scan REP=1 ITERATIONS_PER_VU=100 \
  k6 run --out json=results/manual/scan_28_vus8_rep1.json load-testing/run-target.js   # one cell
analysis/venv/bin/python3 analysis/analyze-results.py --results-dir results/manual
```

- These commands need a host-installed `k6`; the harness scripts run it in a container instead.
- The analysis reads only files named as the harness names them (`baseline_*`, `scan_*`, `warmup_*`, `openloop_*`).
- `warm-up.js` reads `WARMUP_TARGETS` (default `mock calibration 5 10 20 28`), `WARMUP_VUS` (5) and `BASE_URL` (default `http://localhost:8080/api/v1/transactions`). It runs a `constant-vus` executor bounded by `WARMUP_DURATION_S` (15).
- `WARMUP_ITERATIONS_PER_TARGET` switches it to a fixed-count `per-vu-iterations` pass bounded by `WARMUP_MAX_DURATION_S` (60), as the smoke test does. It also bypasses `converge_warmup()`'s gate, so leave it unset for the adaptive warm-up.

#### Overrides

| Script | Variables |
|---|---|
| `run-suite.sh` | `TARGETS_OVERRIDE`, `CONCURRENCY_OVERRIDE`, `REPS_BASELINE_OVERRIDE`, `REPS_SCAN_OVERRIDE`, `BASELINE_ITERATIONS_OVERRIDE`, `SCAN_ITERATIONS_PER_VU_OVERRIDE` |
| `run-ablation.sh` | `ABLATION_CELLS_OVERRIDE`, `REPS_ABLATION_OVERRIDE`, `ABLATION_VUS_OVERRIDE`, `ABLATION_TARGET_OVERRIDE`, `ABLATION_CALIB_ITER_PER_VU_OVERRIDE`, `ABLATION_CALIB_TARGET_DURATION_S_OVERRIDE` |
| `run-openloop.sh` | `OPENLOOP_TARGET` (28), `OPENLOOP_FRACTIONS` (`1.0 0.8`), `OPENLOOP_RATES`, `OPENLOOP_REPS` (7), `OPENLOOP_DURATION` (`2m`), `OPENLOOP_PRE_ALLOCATED_VUS` (64), `OPENLOOP_MAX_VUS` (128), `OPENLOOP_PHASE` (`openloop-check`), `OPENLOOP_COOLDOWN_S` (the suite run's `cooldown_s`); the suite's `WARMUP_*_OVERRIDE` variables, with the same effect |
| `run-predict-composition.sh` | `COMPOSITION_REPS` (7), `COMPOSITION_N` (2000), `COMPOSITION_WARMUP` (200), `COMPOSITION_COOLDOWN_S` (the suite run's `cooldown_s`) |
| `run-suite.sh`, `run-ablation.sh`, `run-openloop.sh`, `run-predict-composition.sh` | `THERMAL_WARN_C_OVERRIDE`, `THERMAL_CRIT_C_OVERRIDE`, `THERMAL_COOLDOWN_S_OVERRIDE`, `MAX_THERMAL_COOLDOWNS_OVERRIDE`, `THERMAL_MAX_COOLDOWNS_EXTENDED_OVERRIDE` |
| `run-suite.sh`, `run-ablation.sh`, `run-all.sh`, `verify-guards.sh` | `REQUIRED_TURBO_OVERRIDE` (`on` or `off`, default `off`); `run-openloop.sh` and `run-predict-composition.sh` require the turbo their suite run recorded |

- `ABLATION_ITERATIONS_PER_VU_OVERRIDE` only sets a metadata fallback: a measured cell's count always comes from calibration, so the two `ABLATION_CALIB_*_OVERRIDE` variables are what shrink an ablation slice.
- `run-smoke-test.sh` sets these variables to a small slice. Unset, each script runs its full default design.

---

## Outputs

### Run directories

- Each `run-suite.sh` or `run-ablation.sh` invocation writes one run directory, `results/<kind>_<host>_<UTC timestamp>/`. `<kind>` is `suite` or `ablation`; `<host>` is the hostname, lowercased and reduced to `[a-z0-9.-]`.
- Starting a run moves this machine's previous run of the same kind to `results/archive/`. Runs of the other kind, and runs copied in from other machines, stay in place.
- A machine is its hostname plus a hash of its machine ID, so a copied run from a same-named host is not archived. Give each host a distinct hostname anyway, since the hostname labels its runs in every table.
- Result files left directly in `results/` (the flat layout) move to `results/archive/<timestamp>/` (`<timestamp>_ablation/` for the ablation's) on the next run of their kind.
- Docker Compose receives the run directory as `RUN_RESULTS_DIR`; a hand-started stack writes to `results/` itself.

### Suite run files

`run-suite.sh` writes into `results/suite_<host>_<timestamp>/`:

| File | Contents |
|---|---|
| `baseline_<target>_rep<N>.json.gz` | One file per baseline cell |
| `scan_<target>_vus<V>_rep<N>.json.gz` | One file per (target, concurrency, rep) scan cell |
| `warmup_baseline_rep<N>.json.gz`, `warmup_scan_rep<N>.json.gz`, `warmup_scan_maxvus_rep<N>.json.gz` | Warm-up latency, tagged `phase=warmup`, for the convergence check |
| `calib_<target>_vus16.json.gz`, `calib_warmup_scan*.json.gz` | The calibration pass's measurement per target and its warm-up; not read by the analysis |
| `calibration_log.txt` | The iteration counts per concurrency level that every scan rep ran each target with |
| `run_order_log.txt` | Shuffle order per repetition |
| `run_metadata.json` | Run identity, toolchain, host, power state, services and configuration (below) |
| `cpu_pin_check_log.txt` | Per-repetition requested-vs-live cpuset, including the `smt_check` lines |
| `env_trace_log.txt` | `env_sample` at both ends of every rep (governor, per-core frequency, hottest thermal-zone temperature, throttle counters); `cell_start`/`cell_end` around every measured cell (temperature, package and per-core throttle counters, `na` where not exposed); `cell_freq` per cell (each service's busy-weighted clock and busy share); `thermal_check` per safety check, with its pause. Per-core values are `cpuN=value` pairs in core order |
| `connection_placement_log.txt` | Per measured cell, the inbound connections each python-service worker held: `placement` at the cell's start and at every change (sampled every 200 ms), then `placement_end`. `placement_unavailable` with a reason where the container's processes cannot be read; the cell runs regardless |
| `run_failures_log.txt` | Empty on a valid run; any entry makes `analyze-results.py` reject the run |
| `gc-logs/gc_<phase>_rep<N>.log` | JVM GC events for that rep, from its last pin-check probe to the service JVM's exit |

`run_metadata.json` records:

- **Identity:** run ID, timestamp, hostname and machine-ID hash.
- **Toolchain and code:** Docker and Compose versions, k6 image digest, git commit and dirty flag, and the measurement fingerprint: a SHA-256 over the working-tree content of every tracked file under `docker-compose.yml`, `services/` and `load-testing/`, excluding their tests, the probes and model training. It hashes file content including comments, so a comment edit in a measured file changes it; untracked files are not covered (`git_dirty` flags them).
- **Host:** CPU and RAM, CPU governor and frequency snapshot, `wsl2_detected`, and host provenance: `isolcpus` live state and boot cmdline, AC/battery power source, `irqbalance` status and virtualization as reported by `systemd-detect-virt`.
- **Power state** (`power_state`), the state every cell is checked against: power source, turbo and the turbo the run required, governor, energy preference, power profile, `thermald`, and the sustained and short-term package power limits from both RAPL interfaces (MSR and MMIO).
- **Services:** each service's cpuset, CPU quota and CPU count (the `*_cores` fields count logical CPUs), and `physical_core_isolation`, the physical cores behind each cpuset.
- **Configuration:** the JVM pinned options and the run configuration, including uvicorn workers and thread-limiter tokens.

### Other run output

- **`run-predict-composition.sh`** adds to the suite run it checks:
  - `predict_composition.json` (schema 2), written only after every rep: per file, the image ID, call counts, numeric thread environment and Python, XGBoost, pandas, NumPy, scikit-learn and joblib versions, which every rep must share; per rep, its tier order, CPU affinity, CPU-quota check (`verified` or `unverifiable`, with the cgroup source) and, per tier, median and P25/P75 of each stream (total, traversal, in-place), the conversion median and share, N, `n_jobs` and the largest score difference between the streams;
  - `predict_composition_reps/rep<N>.json`, each rep's own file, which the merged file is built from;
  - `composition_env_trace_log.txt` (thermal checks and an `env_sample` at both ends of every rep) and `composition_failures_log.txt` (one line per abort; empty on a complete check).
- **`run-openloop.sh`** adds to the suite run it checks:
  - `openloop_<target>_rate<R>_rep<N>.json.gz`, one per rate and rep;
  - `openloop-warmup_<target>_rep<N>.json.gz` and `openloop-warmup_<target>_maxvus_rep<N>.json.gz`, the gated warm-up passes (not read by the analysis; the hyphen keeps them out of both the `openloop_` and `warmup_` patterns);
  - `openloop_log.txt`: per invocation, target, plateau, fractions, rates, reps and the settings the stack ran with; per rep, the rate order and each warm-up pass's gate verdict;
  - `openloop_cpu_pin_check_log.txt` (the recorded-setting, topology, pinning, JVM and tier checks), `openloop_env_trace_log.txt` (per-rep `env_sample`s and per-cell thermal and clock samples), `openloop_connection_placement_log.txt` and `gc-logs/gc_openloop-<target>-rep<N>.log`;
  - `openloop_failures_log.txt`: one line per abort, tagged with target and rep; empty on a complete check. The analysis never reads `run_failures_log.txt` for either check;
  - `archive/openloop_<timestamp>/`: a target's cells, warm-up files and failure lines from an earlier invocation.
- **`run-ablation.sh`** writes the same shapes into `results/ablation_<host>_<timestamp>/` under `ablation_` prefixes: `ablation_<arm>_<value>_rep<N>.json.gz`, `ablation_warmup_*`, `ablation_calib_*` (the calibration pass's measurement and warm-up per cell), `ablation_calibration_log.txt`, `ablation_run_order_log.txt`, `ablation_run_metadata.json` (the same host and toolchain fields as `run_metadata.json`, plus each arm's control value), `ablation_cpu_pin_check_log.txt`, `ablation_env_trace_log.txt` and `ablation_run_failures_log.txt`.
- **`run-all.sh`** writes each step's console output to `results/logs/run-all_<timestamp>/`: `run-all.log` (one line per step), `suite.log`, `openloop.log`, `composition.log`, `ablation.log`, `analysis_suite.log` and `analysis_ablation.log`. The analysis scripts never read `logs/`.
- **k6 results are filtered before storage.** k6 writes its full output to the run directory's `raw/`; `finalize_result()` keeps only the metrics the analysis reads (`KEEP_METRICS`), gzips the result into the run directory and deletes the raw copy. `raw/` is removed once the run completes.
  - `KEEP_METRICS` includes `request_http_error` and `request_timeout_error`, for `crosscheck_error_counters()`'s independent error count, and `java_execution_time_ms`, the Java-side total behind table 2's derived columns.
  - The filter (`lib/k6_filter.py`) reads each line's metric name from k6's fixed JSON prefix, with a full parse for any line not in that shape.

### Analysis output

- `analyze-results.py` and `analyze-ablation.py` analyze every run of their kind under `--results-dir` (default `results/`, excluding `archive/`); the option also takes one or more run directories. A `results/` holding result files directly (the flat layout) is analyzed as one run.
- Each run's output goes to `analysis/output/tables/<run>/` and `analysis/output/figures/<run>/`, named after its run directory, each table as `.csv`, `.md` and `.tex`.
- Every invocation first removes all output folders of its kind, so `analysis/output/` holds exactly the runs last analyzed.
- A run with entries in its failures log is reported and skipped, and the script exits non-zero.

Statistics: P50/P95/P99 and latency histograms per target, Mann-Whitney U tests on rep means between adjacent targets or concurrency levels (Holm-Bonferroni corrected, rank-biserial effect sizes), cluster bootstrap CIs over reps (tables 1, 4 and 7, and the ablation), and CoV% across reps for reproducibility.

Table 2 (`table2_baseline_python_decomposition_mean_ms`) is the VUS 1 decomposition per target: the mean of every Python stage, the serialization estimate's share of the Python total, and the estimated bridge overhead with its negative rate and minimum. Two derived columns cover the fields k6 does not record, both as differences of means:

- `Java-side overhead (ms)`: Java execution time minus bridge minus Python total, i.e. preprocessing, the gap before `netStart` and result mapping;
- `Client-side remainder (ms)`: k6's request duration minus Java execution time, i.e. the k6 hop, Netty's read, the response DTO build and its encoding.

| | |
|---|---|
| Main suite | `table0_warmup_convergence_check`, `table1_baseline_e2e_latency_pooled`, `table1b_baseline_between_run_consistency`, `table1c_baseline_error_rates`, `table1d_baseline_client_diagnostics`, `table1e_measurement_floor_violations`, `table2_baseline_python_decomposition_mean_ms`, `table3_dataframe_share_of_computation`, `table4_concurrency_scan_summary_pooled`, `table4b_scan_between_run_consistency`, `table4c_scan_error_rates`, `table4d_scan_client_diagnostics`, `table4e_scan_within_cell_drift`, `table5_baseline_adjacent_tier_significance`, `table6_scan_adjacent_concurrency_significance`, `table_gc_overhead`, `table8a_thermal_by_group`, `table8b_thermal_pauses`, `table8c_thermal_latency_association`, `table4f_scan_outlier_cells` when any scan cell is flagged, `table4g_scan_connection_placement` when the run recorded placement, `table7_openloop_validity_check` when open-loop files are present, and `table9_predict_proba_composition` when `predict_composition.json` is present |
| Figures | `figure1_baseline_decomposition_stacked_bar`, `figure2_baseline_latency_distribution`, `figure3_p95_latency_vs_concurrency`, `figure4_throughput_vs_concurrency`, `figure5_decomposition_vs_concurrency_v<tier>`, `figure6_between_run_reproducibility_baseline`, `fig_gc_overhead`, `figure8_thermal_timeline`, and `figure7_openloop_validity_check` and `figure9_scan_connection_placement` when applicable |
| Ablation | `table0_ablation_warmup_convergence_check`, `table_ablation_error_rates`, `table_ablation_decomposition`, `table_ablation_control_agreement`, `table_ablation_control_vs_extreme`, `table_ablation_thermal_by_cell`, `table_ablation_thermal_pauses`, `table_ablation_thermal_association`, `figure_ablation_mechanisms`, `figure_ablation_thermal_timeline` |

Tables that report the run's own conditions:

| Table | Reads as |
|---|---|
| `table0*` | One row per warm-up pass and target, including targets that never reached three windows or never returned HTTP 200, with the gate's status. `no`: the target entered its measured phase still moving |
| `table4_concurrency_scan_summary_pooled` | The `Sampling` column explains why N jumps by orders of magnitude between rows: `Iteration-based` levels run a fixed count per virtual user; duration-targeted levels, labeled `Duration-calibrated` (`CALIB_AFFECTED_LEVELS`, from the run's `run_metadata.json`), run to a fixed wall-clock target, producing far more requests at the same VUS |
| `table4e_scan_within_cell_drift` | Mean change from the first to the second half of each scan cell, with a t-interval across reps. The same sign in every rep means the cell mean depends on its duration, which duration targeting holds near 60s at VUS 8 and above |
| `table4f_scan_outlier_cells` | Scan cells whose mean latency sits far above their design cell's other reps: modified z-score above 3.5 and at least 5% above the median rep. A median shift as large as the deviation: the whole cell moved, not just its start. Compute stall above the other reps': Python threads waited off-CPU. `Placement`: connections per python-service worker, busiest first. `Python clock`: its service-core clock |
| `table4g_scan_connection_placement`, `figure9_scan_connection_placement` | Scan cells per concurrency level, grouped by crowding above the even split. Crowding is the number of connections on the worker serving a connection, itself included, averaged over connections (sum of squared per-worker counts over the total); the most even split has the lowest. Per group: latency deviation, extra compute stall, and a Mann-Whitney test against the even cells, cells as units. Uneven cells running slower with raised compute stall: that level's between-rep spread follows placement |
| `table8a_thermal_by_group`, `table_ablation_thermal_by_cell` | Per design group: temperature at both cell edges, whether any service's cores were throttled, and each service's median CPU clock. `not exposed`: the host publishes no throttle counters, so throttling is unmeasured, not absent. In loaded cells, a clock below the group's usual value marks cells that ran on slower hardware, whatever their latency; at light load the reading runs low ([Measurement controls](#measurement-controls)) |
| `table8b_thermal_pauses`, `table_ablation_thermal_pauses` | How often each phase paused for heat, and the wall-clock minutes it cost |
| `table8c_thermal_latency_association`, `table_ablation_thermal_association` | Spearman correlation of a cell's temperature, throttling or service-core clock with its latency, as the deviation from its design cell's mean across reps so the manipulated factor cannot register as heat. Near zero: thermal state does not explain the between-rep spread |
| `table7_openloop_validity_check`, `figure7_openloop_validity_check` | Per tier and open-loop rate, and for the scan's top two VUS levels: P95 and P99 per rep, as the median across reps with the min-max range, reps and reps with HTTP 200, the pooled P95's cluster-bootstrap CI, N per rep and in all, and dropped iterations summed over reps with the largest single-rep count. Open-loop tails close to the closed-loop ones, with no drops below the plateau: the closed-loop scan's tail is not an artifact of coordinated omission |
| `table9_predict_proba_composition` | Per tier, each as the median across reps with the min-max range: median `predict_proba` time, median booster time on a pre-built `DMatrix`, their difference and its share of the total, the booster's in-place call on a pre-built array and the share against it (the lower bound); plus reps and N per rep. A share near 100%: the model-inference field measures input conversion, not the model |
| `table_ablation_error_rates` | Every ablation request's outcome and the iterations k6 dropped, counted before sampling, since the ablation's latency tables cover HTTP 200s only |

---

## Measurement controls

Conditions that invalidate a measurement abort the run; conditions with no single correct value are recorded.

### Enforced

An abort (`abort_suite`) stops the run at once and writes a tagged entry to `run_failures_log.txt`. No results are written for that rep, earlier reps on disk are unaffected, and `analyze-results.py` rejects any run whose failures log has entries, so there are no partial runs.

The open-loop and composition checks apply the same controls (below) and abort the same way, but into their own `openloop_failures_log.txt` and `composition_failures_log.txt`. An entry there marks table 7 or table 9 with a notice and leaves the suite run, and its other tables, valid.

- **Recorded settings, open-loop and composition checks.** Both start from the suite run's `run_metadata.json`, not from compose's current defaults: the open-loop stack from the recorded cpusets, CPU quotas, worker count and thread-limiter tokens, checked against the resolved compose configuration along with `JAVA_TOOL_OPTIONS`; the composition container from the recorded Python cpuset and quota, both checked from inside it. Missing values are refused.
- **CPU pinning, every rep.** A `cpuset` in `docker-compose.yml` is a request, not proof of what the cgroup applied. The requested cpuset (`docker inspect --format '{{.HostConfig.CpusetCpus}}'`) is compared with the live one (`docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective`, cgroup v2 with a v1 fallback) and logged in `cpu_pin_check_log.txt`. A live cpuset the cgroup does not expose is logged as `WARN_SKIPPED`, not a mismatch, and `analyze-results.py` reports the count.
- **Physical-core isolation, before any container starts.** `verify_smt_isolation()` resolves each cpuset to physical cores through `thread_siblings_list` and aborts if python, java and k6 share cores through SMT siblings; disjoint cpusets do not imply disjoint hardware.
- **Single-threaded inference.** `n_jobs=1` is read back at model load and after real inference (`nJobsVerified` / `nJobsRuntimeVerified` on `/health`). `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS` and `NUMEXPR_NUM_THREADS` are pinned to 1 and asserted from `/health` every rep, since `n_jobs` does not constrain the BLAS layer.
- **Feature tiers and thread limiter, every rep.** `/health` must report `loadedTiers` of `5,10,20,28` (python-service loads every `FEATURE_TIERS` entry on start, whichever targets the run uses), `nJobsVerified` true for every tier, and the pinned thread-limiter token count. This catches a silent tier-load failure, which would corrupt AI-tier cells without any request-level error.
  - `THREAD_LIMITER_TOKENS` (default `40`) sets anyio's limiter capacity as an explicit parameter rather than the library default.
  - Java fetches the tier set from `/health` at startup; it is never hardcoded.
- **JVM pins, every rep.** At rep start, G1 and its worker-thread ceilings are read back with `-XX:+PrintFlagsFinal` (`lib/jvm-pins.sh`), including each flag's *origin*, which separates a value the compose file set from one that coincides through JVM ergonomics. The Reactor Netty event-loop count is a system property, absent from that dump, so after warm-up, once every event loop has served traffic, a `/proc` thread census counts live GC and event-loop threads against their ceilings.
- **CPU power state, every rep and both edges of every measured cell** (`lib/power-state.sh`). Start requirements: [Prepare the host](#2-prepare-the-host-before-every-run). The whole recorded state (power source, turbo, governor, energy preference, power profile, `thermald`, package power limits) is compared, and any change, e.g. an unplugged charger or a firmware power-limit change, aborts with a `[power]` entry. The check compares settings, not the clock frequency itself, which is recorded per cell instead (`cell_freq`). `lib/cpufreq_sampler.py` also aborts a cell during which mains power was lost.
- **Heat, after every cell and warm-up chunk** (`lib/thermal.sh`), from every readable `thermal_zone*`:
  - at or above `THERMAL_WARN_C` (90C): pause `THERMAL_COOLDOWN_S` (60s) and check again;
  - `MAX_THERMAL_COOLDOWNS` (2) rounds always, then more while each is colder than the last, up to `THERMAL_MAX_COOLDOWNS_EXTENDED` (10) in total;
  - still at or above `THERMAL_CRIT_C` (95C) when the pausing stops: abort;
  - every check is logged with its pause, so the run's thermal cost is measured rather than absorbed into the numbers.
- **Cell failures.** A failed k6 run, an OOM kill or a readiness timeout aborts the run. Request-level errors inside a completed cell (non-200 responses, timeouts) do not: tables 1c and 4c count them, and every latency table covers HTTP 200 requests only.

### Fixed by configuration

- **Outbound connection pool:** `run-suite.sh` and `run-ablation.sh` size Java's pool to Python at 2x the run's peak VUS, and `run-openloop.sh` at 2x `OPENLOOP_MAX_VUS` (`PYTHON_SERVICE_MAX_CONNECTIONS`, logged at startup and in `openloop_log.txt`), so pool queueing cannot become the bottleneck or appear as network or Python cost. A hand-started stack uses `128`.
- **Per-request logging off** on both services (Java: `TransactionService` at `WARN`; Python: `uvicorn --no-access-log`): a synchronous stdout write would stall the WebFlux event loop or the request coroutine, adding noise unrelated to inference.

### Recorded

- **Stage timing** in every response ([API](#api)). Java: preprocessing, AI-call round trip, bridge estimate, DB write, response build. Python: parsing, thread dispatch, DataFrame construction, model inference, compute stall, serialization. WebFlux's encoding of the Java response body is timed by neither service; it falls in table 2's client-side remainder.
- **Client-side errors and contention.** Timeouts and connection errors (`status=0`) are counted apart from HTTP errors. `http_req_blocked` (client connection contention) is reported so a throughput plateau can be checked against the load generator.
- **Connection-to-worker placement**, every measured cell: which python-service worker holds each inbound connection, read from the host's procfs by `lib/placement.py` (what `ss -tnp` reports), on CPUs outside every service's cpuset, executing nothing in the measured container. At low concurrency it decides whether two in-flight requests contend for one worker's GIL.
- **Thermal state and clock** (`env_trace_log.txt`, [Suite run files](#suite-run-files)), reported per cell with pause costs and a test against latency (tables 8a to 8c). The clock is `scaling_cur_freq` sampled every 0.5s and weighted by busy time; on cores busy only part of the time it can read below the clock the work ran at, so it is informative for loaded cells, not light ones.
- **Host provenance** (`lib/host-provenance.sh`), at the start of every run: kernel `isolcpus`, whether `irqbalance` is migrating interrupts across pinned cores, and virtualization. They can shift latency without appearing in this project's configuration, but none has one correct value for every host, so they are recorded, not enforced. The cross-host analysis gates on all three.
- **JVM GC events**, one log per rep (`gc-logs/gc_<phase>_rep<N>.log`), to cross-check tail spikes against GC pauses. The rep's pin-check probe JVMs share the container's `JAVA_TOOL_OPTIONS`, and the last of them reopens `gc.log` before warm-up, so each log spans the rep from its verification to the service JVM's exit; the GC table measures that window by the records' wall-clock timestamps. Unified JVM logging has negligible overhead and is off the request path.

---

## Experimental design rationale

- **7 repetitions per cell.** Each rep is a clean-slate restart, so the count trades wall clock against test resolution. With rep means as the unit, the rep count fixes the smallest p-value a Mann-Whitney test can reach, however large the effect; 7 is chosen so that perfect separation clears α after correction. It is not derived from a power analysis.
  - At 7 vs 7 the smallest two-sided Mann-Whitney p-value is `2/C(14,7) = 0.00058`, 0.0029 after Holm correction across the five adjacent-target comparisons: still below α=0.05.
  - At 5 vs 5 it is 0.0079, or 0.0397 corrected: significant, with no margin for one noisy rep.
  - `pairwise_mannwhitney` prints a `[!]` warning whenever even perfect separation cannot clear alpha at the realized rep count (0.333 at 2 reps per side), so "Significant: No" there reads as unresolvable at that rep count rather than null. Achieved N is printed with every result.
- **Rep-level statistics.** Requests within a rep share a JVM, a page cache and a thermal state, so they are not independent. Significance tests rank per-rep means, and CIs are cluster bootstraps over whole reps. Table 5's pooled request-level p-values are pseudoreplicated and marked *diagnostic only*.
- **Throughput measured within each repetition**, then averaged; a span pooled across reps would include the restarts and cooldowns between them. It is `(N-1)/span`, since N completion timestamps bound N-1 intervals. Calibration, table 4, figure 4 and `lib/openloop_rates.py` share this convention, so a derived iteration count and a reported throughput are the same quantity.
- **Closed-loop load for the main suite.** `per-vu-iterations` fixes the number of in-flight requests, matching a bounded caller pool and preventing unbounded queue growth in high-concurrency cells. Its known cost, coordinated omission, is checked by `run-openloop.sh` at and below the top cell's throughput; table 7 is the validity check on the closed-loop tail, not a competing result.
- **Duration-targeted cells.** Throughput differs by a large factor between targets, so a flat `ITERATIONS_PER_VU` would give a trivial target a cell of seconds and an AI tier one of minutes. `calibrate_target()` measures each target's throughput and derives the count that makes every cell at VUS 8 and above span about 60s; VUS 1, 2 and 4 keep the flat `SCAN_ITERATIONS_PER_VU`.
  - `calibrate_scan_targets()` prepares a stack exactly like a scan rep (restart, pin, JVM and tier checks, both warm-up passes), measures each target at `CALIB_VUS=16`, and derives `ITERATIONS_PER_VU` for each of `CALIB_AFFECTED_LEVELS` (8, 16, 32, 64) against `CALIB_TARGET_DURATION_S` (60s).
  - It writes `calib_*.json.gz`, which the analysis ignores, and `calibration_log.txt`.
- **The calibration pass runs once, before the reps it serves, without running a measured cell**, so every rep of a cell runs the same workload after the same load history. Calibrating inside the first rep would give that rep an extra load period; calibrating every rep would let the workload vary. Rep-to-rep throughput drift only moves a cell's duration around 60s, and table 4e shows how much a cell mean depends on duration.
- **Turbo off, as a fixed run parameter.**
  - With turbo on, a cell's clock depends on how many cores are busy (one busy core boosts higher than many sharing the power budget), so the concurrency scan would vary clock speed along with concurrency.
  - On a laptop it also depends on heat: the host runs at full power until near its thermal limit, then the firmware cuts power, so a cell's clock depends on heat left by earlier cells. Randomized order spreads that dependence but does not remove it.
  - With turbo off, busy cores run at base clock whatever the concurrency level, the heat that would pause or throttle a run does not arise, and the setting is available on other hosts, where turbo behavior depends on each machine's cooling.
  - `REQUIRED_TURBO_OVERRIDE=on` runs the design with turbo; the setting is recorded and gated.
- **Order randomization.** Targets and concurrency levels are shuffled independently per rep, so thermal drift or a background daemon cannot systematically favor one target.
- **Fixed model hyperparameters.** `max_depth=4`, `learning_rate=0.1`, untuned. Accuracy is not an outcome; tuning would change latency without making any claim more valid.
- **Warm-up gated on convergence, not a fixed budget.** `warm-up.js` hits every target sequentially, each in its own window, and shares code with `run-target.js`, so warm-up traffic is tagged and classified like measured traffic. `converge_warmup()` re-runs it in 15s chunks (`WARMUP_CHUNK_DURATION_S`), up to four per warm-up pass (`MAX_WARMUP_CHUNKS`), until every target has settled. The criterion, `load-testing/lib/warmup_gate.py`, is shared by both harness scripts, the probes and table 0:
  - Per target, the median of the last window of HTTP 200 latencies is compared with the window before it, passing on whichever bound is looser: a change under 5%, or a gap under 0.25 ms (a percentage alone is unreachably tight for sub-millisecond targets).
  - A window is at least 500 requests and at least 3s of the target's own traffic. At the zero-work targets' throughput, 500 requests span tens of milliseconds, shorter than GC and scheduler timescales, so two such windows would read transient states as drift. Three windows still fit in one chunk at every target's throughput.
  - Every exercised target must converge; one with no HTTP 200 response never does.
  - If four chunks are not enough, the run proceeds from that state and table 0 records every target's verdict.
- **Warm-up convergence judged on the tail.** Table 0 reports drift from the first window, large by design, and between the last two windows; only the latter indicates steady state and gates `Converged`.
- **Counts, extremes and throughput corrected for subsampling** (tables 1, 4 and 7). `load_results()` pools every metric in a file into one subsampling cap, so a cell logging several metrics per request can trip the cap while each metric's own count stays under it, deflating N and throughput by about the subsampling ratio; a uniform sample also rarely keeps a cell's fastest and slowest request. A side channel keeps each cell's exact count, time span and value range, and `summarize`, `error_summary` and `_throughput_reqs_per_s` report from it. Table 6's diagnostic-only Pooled N is not corrected, since that would also require recomputing its diagnostic p-value on the full data.
- **A fully failed open-loop cell keeps its table 7 row.** Cell identity comes from all `http_req_duration` points regardless of status, so a cell where nothing succeeded, the case the check exists to surface, reports `N=0` with its `dropped_iterations` count.
- **The validity checks at the suite's controls.** Table 7 and table 9 are compared with the suite's own cells, so a difference must not come from a lighter setup: both checks run on the suite run's recorded settings and power state, with the suite's guards, 7 reps each with a fresh start (a stack restart, or a fresh container), shuffled order and cooldowns, and both tables take the rep as the unit. A check costs wall clock rather than validity: about 50 and 5 minutes at the defaults.

---

## Threats to validity

### Construct validity: does the instrumentation measure what it claims?

- **`calibration` is a floor, not subtracted.** Instrumentation overhead stays in the AI and mock numbers.
- **`modelInferenceTimeMs` is the whole cost of obtaining a prediction**, and on this stack it is dominated by XGBoost's ingestion of the pandas DataFrame, not the booster. At the pinned XGBoost (2.1.1), `predict_proba` on a DataFrame takes the in-place prediction path: it converts the frame column by column on every call, without building a `DMatrix`. Booster traversal is near-flat across tiers while the conversion grows with column count, since dtypes are inspected per column per call, so this field's tier scaling is predominantly framework-level input marshalling. It is reported as measured: the service-level cost a service written this way pays, not model-evaluation cost. Table 9 (`run-predict-composition.sh`) measures the split for each run over 7 reps, in the service image on the run's cpuset and CPU quota at its power state. It is measured in-process on a 1-row frame, not through the HTTP path, so it attributes the field's composition, not its absolute value under load.
- **The serialization figure is a self-referential estimate.** `totalPythonExecutionTimeMs` includes an EWMA estimate of serializing the response that carries it; table 2's `Serialization (% of total)` column bounds its effect.
- **`estimatedBridgeOverheadMs` is more than the Docker bridge, and is derived across two independent clocks.** Java computes it per request as its AI call round trip minus Python's self-reported total. It stands for the inter-service hop over the Docker bridge on one host, not a real network, and also absorbs everything else between the two stamps: Jackson encoding of the request and decoding of the response on the Java side, uvicorn's HTTP parsing and response writing, any queueing before P0 (the `TimingMiddleware` stamp, taken in the outermost application middleware), the serialization estimate's (EWMA) error, and a TCP connect on each cell's first requests, since uvicorn closes a connection after 5s idle and cells are 10s apart. At VUS 1 the pre-P0 wait is near zero, so the estimate is close to transport and framing; at high concurrency that wait grows, so a rising bridge figure in the scan reads as queueing in Python before P0, not a slower hop. It can be negative and is not clamped: table 2 reports the negative rate and minimum per tier. A small, tier-consistent rate is inter-process timer noise; a large or tier-clustered rate would be a measurement fault.
- **Requests can complete below the physical floor.** Table 1e counts model-inference requests faster than the fastest `calibration` request: timing artifacts, so the affected tier's minimum is not a real latency. `mock` is not checked, since its distribution coincides with calibration's and about half its fastest requests fall below calibration's single fastest by sampling alone.
- **Single-threading is a strong, not absolute, guarantee** ([Measurement controls](#measurement-controls)).
- **The zero-compute baselines are noisier in relative terms.** `mock` and `calibration` have no compute term to dilute scheduling and queueing jitter, so their coefficient of variation and tail-to-median ratio run well above the AI tiers'. This is a property of what they measure, not harness instability, and is why the warm-up window is defined by time rather than request count. At low concurrency their rep means, and thread dispatch at VUS 1, can vary by more than the cross-host equivalence margin, so ratios built on them can come out inconclusive even between runs of one host.

### Internal validity: could something other than the manipulated variable explain the result?

- **Physical-core isolation matters most in the ablation's cpuset arm.** Widening python-service onto higher-numbered CPUs can land it on the SMT siblings of java's or k6's cores, measuring contention rather than CPU count. The isolation check covers every cell; re-pick those values per host.
- **Pinning assumes a native Linux Docker host.** On Docker Desktop (macOS or Windows), `cpuset` inside the VM has no fixed relationship to physical cores.
- **Under WSL2, `verify_cpu_pinning()` can pass while pinning is not real.** The cgroup `cpuset` is honored inside the WSL2 VM, but the Hyper-V host scheduler can migrate the virtual CPUs across physical cores, which no in-VM check can observe. `thread_siblings_list` is often absent too, and the SMT check then reports `unverifiable`.
  - `wsl2_detected` and `physical_core_isolation` are recorded in `run_metadata.json`.
  - **This is disclosure, not mitigation; a native-Linux run is the stronger dataset.** Concurrency-scan tails (E2) are more exposed than the baseline decomposition (E1), since migration risk scales with scheduling pressure.
- **CPU power state: two limits remain.** A change that starts and reverts within one cell shows only in that cell's clock (table 8a), except a loss of mains power, which the clock sampler catches. A host exposing no turbo or governor control, as in most VMs, is recorded as `unexposed` rather than verified.
- **Thermal state is measured per cell and guarded** (tables 8a to 8c). Throttling is read from Intel's `thermal_throttle` counters (Linux 5.18+) and reported as `not exposed` elsewhere, never as zero. The guard stops a heat-soaked host rather than recording cells it cannot cool, and randomized order keeps residual heat from aligning with any one condition.
- **`isolcpus`, `irqbalance` and virtualization are recorded, not enforced**: a run with `irqbalance` active is not blocked. The cross-host analysis gates on all three, `isolcpus` by its coverage of the pinned CPUs.
- **GC pauses are measured, not eliminated.** `table_gc_overhead` reports per-rep pause time as a percentage of wall clock. A rep above about 1%, or with a single pause near the P99, is a candidate confound for that rep's tail.
- **k6 is pinned to its own cpuset and capped at 4 CPUs**, preventing cgroup-level contention with the services, but none of the three is isolated from the Docker daemon or the rest of the host OS. `http_req_blocked` (tables 1d and 4d) is a partial diagnostic; it cannot prove k6 never became the bottleneck at high concurrency.
- **Connection-to-worker placement differs between reps.** python-service runs three uvicorn workers on one listening socket, and each new connection goes to whichever worker accepts it. transaction-service reopens its connections in every cell (uvicorn closes a connection after 5s idle; cells are 10s apart), so at low concurrency two connections can share a worker in one rep and not the next. Requests on a shared worker contend for its GIL, a whole-cell shift with raised compute stall. Placement is recorded and tested against a level's between-rep spread (tables 4f and 4g), not controlled, since assigning connections to workers would change the service under test.

### External validity: how far do the results generalize?

- **Single node only**, with no multi-region or real network-hop path.
- **Every inference call is one row in, one prediction out.** `fraud-ml-service` has no batching path; the results say nothing about batched or dynamically batched serving.
- **Synthetic, uniformly random feature vectors.** The licensed dataset cannot be bundled, so `randomFeatures()` draws in a roughly PCA-shaped range. The exposure is bounded: booster traversal is structure-dominated (near-flat across the four tiers for a depth-4, 100-tree model; table 9), and the dominant DataFrame conversion depends on dtype and shape, not values. The models were trained on real data, so their tree structure reflects it.
- **Reduced feature space even at the largest tier.** `V1..V28` plus `Amount` is the full PCA set available, but the source dataset is itself a reduced, anonymized representation.
- **Core pinning is host-specific.** Results are not comparable across core counts or SMT settings without re-picking `cpuset` values; the SMT check aborts rather than produce incomparable numbers.
- **Results are measured with turbo off.** Absolute latency and throughput are lower than on a turbo-enabled host, and the computation-to-overhead ratio shifts with clock speed: at base clock network, framework and scheduling overhead slow more than computation, so the overhead share of end-to-end latency is higher than a turbo-enabled deployment of the same hardware would show. Within-run comparisons (tier ordering, scaling with concurrency, the ablation's mechanisms) hold every factor but the manipulated one at the same clock. `REQUIRED_TURBO_OVERRIDE=on` measures the turbo case with the same harness.
- **Absolute figures describe one host.** The cross-host analysis tests only within-run ratios; agreement across a few hosts bounds, but does not establish, how far a ratio generalizes.
- **Concurrency-scan P99s rest on unequal N.** VUS 8 and above are duration-targeted, so N varies by target; VUS 1, 2 and 4 use the flat `SCAN_ITERATIONS_PER_VU`. P99 CIs therefore differ in width across a row; the achieved N is printed with every result.
- **Mock and calibration are latency baselines only**, never real fraud checks. `--synthetic` training data is a smoke test, not a benchmark source.
- **In-memory H2 is wiped on restart.** The run's records (`run_metadata.json`, `run_order_log.txt`, `run_failures_log.txt`, `cpu_pin_check_log.txt`, `env_trace_log.txt` and their `ablation_` counterparts) belong to its run directory; a host's previous run of the same kind moves to `results/archive/`.

---

## Cross-host comparison

`analyze-host-variance.py` (suite runs) and `analyze-ablation-host-variance.py` (ablation runs) compare runs of one kind recorded on different hosts, or repeated on one. Copy each host's run directory into `results/`, or name the run directories:

```bash
cd analysis
venv/bin/python3 analyze-host-variance.py              # every suite run under ../results
venv/bin/python3 analyze-ablation-host-variance.py     # every ablation run under ../results
venv/bin/python3 analyze-host-variance.py RUN_DIR RUN_DIR [--margin-pct 10] [--allow-env-mismatch]
```

### What is compared

Absolute latency and throughput scale with hardware, so they are reported as context and not tested. The compared metrics are ratios within each run, paired by repetition, since every cell a ratio uses was measured in the same rep.

| Script | Compared metrics |
|---|---|
| `analyze-host-variance.py` | Each AI tier's model computation time relative to its end-to-end latency at VUS 1; each target's baseline latency relative to `calibration`; each pipeline stage's share of Python time per AI tier at VUS 1, and thread dispatch's share at the highest VUS; throughput relative to `calibration` at the highest VUS; P95 at the highest VUS relative to the lowest. Also reported: the lowest concurrency at which each target reaches 95% of its own peak throughput, and agreement between runs on the ordering of targets (Kendall's W, tie-corrected, with its chi-square test; with few runs the p-value cannot reach 0.05, and the caption states its floor) |
| `analyze-ablation-host-variance.py` | Per arm, thread-dispatch and total Python time at the value farthest from control relative to control, and whether every run's effect points the same way |

### How it is judged

- Each run's ratio carries a 95% bootstrap CI over repetitions.
- Each pair of runs gets the percent difference of every ratio, with 90% and 95% bootstrap CIs, and a verdict against a margin fixed in advance on the ratio of their values (`--margin-pct`, default 10%). The margin is symmetric on the log scale: the ratio must lie within [1/(1+m), 1+m], i.e. −9.09% to +10% at the default, so the verdict does not depend on which run is the reference:
  - `equivalent`: the 90% CI lies inside the margin (two one-sided tests at α = 0.05);
  - `different`: the 90% CI lies entirely outside;
  - `inconclusive`: otherwise;
  - `insufficient reps`: fewer than two repetitions.
- Percentile bootstrap intervals over seven repetitions are approximate, so a CI bound close to the margin is weak evidence either way.

### Environment gate

Runs are compared only when they match on every field the harness or the operator controls.

- **Gated:** measured code (`measurement_fingerprint`, or the git commit when any compared run lacks a fingerprint), run configuration (including uvicorn workers and thread-limiter tokens), JVM pins, k6 image and digest, logical CPU count, CPU quota and physical core count per service, physical-core isolation status, `isolcpus` coverage of the pinned CPUs, `irqbalance`, power source, CPU governor, turbo, WSL2 and virtualization.
- **Gated between runs of one machine only:** package power limits, which are set per model and firmware.
- **Not compared:** CPU numbers, since the same isolation maps to different numbers on different topologies. The ablation's cpuset values are compared by CPU count.
- **Reported, may differ:** hostname, machine-ID hash, CPU model, host logical CPU count, memory, kernel, Docker and Compose versions, git commit and dirty flag, energy preference, power profile and `thermald`.

On a mismatch the script prints both values and exits non-zero; `--allow-env-mismatch` compares anyway and names the differing fields in every caption. A field not recorded by every run is reported as unverified. Runs with entries in their failures log, or without a metadata file, are excluded. Runs sharing a hostname are labeled `<host>-<timestamp>`, and a comparison of runs from one machine is noted in every caption, since it measures between-run rather than between-host variance.

### Output

- Tables go to `analysis/output/hostvariance/tables/` and figures to `analysis/output/hostvariance/figures/`, each named `<table>_<run labels>_<UTC date>` (`<N>runs` in place of the labels when they would make the name too long). Each invocation replaces that script's earlier files.
- Both scripts read one cell file at a time through the per-run scripts' own loaders, so sampling, status filtering and throughput match the per-run tables.

| Suite | Ablation | Contents |
|---|---|---|
| `table_hv0_environment` | `table_ablation_hv0_environment` | Every gated and reported field per run, with its status |
| `table_hv1_portable_metrics` | `table_ablation_hv1_effect_ratios` | Each ratio per run with its CI, the between-run CoV, the largest pairwise difference and the overall verdict |
| `table_hv2_pairwise_differences` | `table_ablation_hv2_pairwise_differences` | Percent difference per pair of runs with 90% and 95% CIs and its verdict |
| `table_hv3_saturation_points`, `table_hv4_order_concordance` | | Saturation concurrency per target; Kendall's W |
| `table_hv5_host_context` | `table_ablation_hv3_host_context` | Absolute figures, rep-to-rep spread and throttled cells per run, with GC overhead (suite) or each arm's own Mann-Whitney test (ablation) |
| `figure_hv1_normalized_throughput`, `figure_hv2_pairwise_differences` | `figure_ablation_hv1_effect_ratios`, `figure_ablation_hv2_pairwise_differences` | Throughput normalized to each run's own peak, or each run's effect ratio; pairwise differences against the margin |

---

## Diagnostics

`load-testing/probing/` holds six standalone diagnostics, not wired into `run-suite.sh` or `run-ablation.sh`. The predict_proba composition check is a validity check rather than a probe, and runs as a `run-all.sh` step ([predict_proba composition check](#predict_proba-composition-check)). They re-derive the harness's tuning constants on a new host, so a reproducer can justify those constants rather than inherit them.

- Each changes to its own directory first, so it runs from any working directory.
- `probe_warmup_joint.sh` and `probe_warmup_settle.sh` write their intermediates to `results/probes/` and clean up after themselves.
- `probe_ablation_taper.sh` and `calibrate_scan_iterations.sh` write into the main `results/` tree and leave their `probe_ablation_*` / `calib_*` files there.

| Script | Question it answers |
|---|---|
| `probe_warmup_joint.sh LABEL VUS [...]` | Does the real gate condition, every target converging in the same chunk, become reachable, and which target lags when it does not? Runs past `MAX_WARMUP_CHUNKS` and prints every target's verdict at every checkpoint from `lib/warmup_gate.py` itself, at the production window, minimum span, tolerance and floor unless overridden |
| `probe_warmup_settle.sh LABEL TIER VUS [...]` | Where does a single non-converging target settle? Same chunks, one target, past the cap, with a thermal check after each. `WARMUP_WINDOW_OVERRIDE` / `WARMUP_MIN_SPAN_OVERRIDE` / `WARMUP_TOL_OVERRIDE` / `WARMUP_ABS_FLOOR_OVERRIDE` change the criterion, to test how a target's verdict depends on the window and bounds at its own per-request variance |
| `calibrate_scan_iterations.sh TIER [REF_VUS] [TARGET_DURATION_S] [CALIB_ITER_PER_VU]` | What `ITERATIONS_PER_VU` does each concurrency level need on this host to hit a target cell duration? The derivation `calibrate_target()` runs, in inspectable form |
| `probe_calibration_drift.sh TIER [N_MEASUREMENTS] [REFERENCE_VUS] [ITER_PER_VU] [COOLDOWN_S]` | Does a target's calibration-pass throughput hold constant across reps, as the once-per-target calibration pass assumes? Repeats `calibrate_target()`'s measurement back to back and reports the spread |
| `probe_ablation_taper.sh LABEL CPUSET CPUS WORKERS TOKENS [TARGET_DURATION_S]` | Does an ablation arm's processing capacity change the cell duration it needs? Checked per arm, since each arm changes python-service's throughput by design |
| `probe_telemetry_completeness.sh [N_REQUESTS] [TARGET...]` | Is every telemetry field present on a live response, for every target? Checks build freshness against source mtimes first, then all eight `python_*` and two `java_*` fields per response |

`analysis/probing/plot_warmup_curve.py` is a seventh diagnostic, for thermal investigation rather than warm-up tuning:

- It overlays rolling P50 latency against active VUs, package temperature and core frequency within one result file (`.json` or `.json.gz`), so a throttle signature can be read against the load rather than inferred from temperature alone.
- Options: `--thermal-log` (a `sensors` poll) and/or `--turbostat-log`; `--results-dir` names a run directory.
- The active-VU line needs the `vus` metric, which finalized files omit. `calibrate_scan_iterations.sh` writes with a bare `--out json=`, bypassing the harness's filter, so its raw file still has it.

---

## Tests

The measurement instruments are unit-tested, since every reported figure depends on them. No suite runs during the Docker build, so the measured images carry no test tooling and match what is shipped.

`./install-test-deps.sh`, run once from the repo root, sets up every toolchain below: a JDK 21+ if none is installed, `analysis/venv` with its `requirements-dev.txt`, `services/fraud-ml-service/.venv` with its own `requirements-dev.txt`, and `bats-core` 1.5+. It is separate from `setup.sh`, which prepares only the measurement stack. Maven fetches its test dependencies (JUnit, `spring-boot-starter-test`, `reactor-test`) on the first `./mvnw test`.

```bash
./install-test-deps.sh                                                     # once
(cd services/fraud-ml-service && .venv/bin/python3 -m pytest tests/ -q)    # Python service: 63 tests
(cd analysis && venv/bin/python3 -m pytest tests/ -q)                      # analysis and harness Python libraries: 215 tests
(cd services/transaction-service && ./mvnw test)                           # Java service: 37 tests
(cd load-testing && bats tests/)                                           # load-testing harness (bats-core): 173 tests
```

What they guard:

| Test | Protects |
|---|---|
| `test_responses.py` convergence tests | The EWMA serialization estimate stays sub-millisecond and cannot drift, bounding the circularity in `totalPythonExecutionTimeMs` |
| `test_model.py` timing and `n_jobs` tests | Compute stall is never negative and never exceeds wall time; computation covers its own components; `n_jobs=1` is verified on the first real prediction and an unpinned model is flagged |
| `test_api.py` telemetry symmetry | All three arms emit identical telemetry fields, the precondition for decomposition by subtraction; `/health` reports the numeric thread environment |
| `test_api.py` baseline-floor tests | `mock` and `calibration` report zero compute, so they bound inference cost |
| `test_model.py` error-classification tests | A `ValueError` raised inside `predict_proba` (a server-side fault) reports 500, distinct from the 400 the same exception type gets as the explicit too-few-features check |
| `test_library_contracts.py` | Third-party behavior the measurement design assumes, at the locked versions, using the committed models: XGBoost's `predict_proba` on the request frame goes through `Booster.inplace_predict` with feature-name validation and never constructs a `DMatrix`, converting the frame on every call; the request frame is one `float64` row named exactly as each tier's model features; Starlette's built stack is `ServerErrorMiddleware`, then `TimingMiddleware` (P0), then `ExceptionMiddleware`; `THREAD_LIMITER_TOKENS` reaches the default anyio limiter the thread hand-off holds (anyio's default is 40); `time.thread_time` stops while a worker sleeps or blocks during another thread's work and advances while it computes, the premise of compute stall |
| `TransactionServiceTest` | `estimatedBridgeOverheadMs` is exactly round-trip minus Python total, negative values are preserved, and `netStart` is captured at `Mono` subscription, so a gap between building and subscribing to the call is not charged to `aiCallRoundTripTimeMs`; `dbWriteTimeMs` stays 0 with persistence off; every telemetry field passes through; each arm routes to its own endpoint; an unconfigured or missing tier, too few features or an unknown strategy is rejected; an upstream 5xx maps to 502 and a 4xx to 400; a `TimeoutException` or Netty `ReadTimeoutException` as the transport cause maps to 504, and a Netty connect timeout, which is a `ConnectException` rather than a `TimeoutException`, to 502 |
| `GlobalExceptionHandlerTest` | A `ResponseStatusException` (e.g. Spring's 415 for an unsupported `Content-Type`) reports its own status rather than the generic 500 |
| `RequestTimingWebFilterTest` | The request-start stamp anchoring every Java-side figure is taken at highest filter precedence |
| `test_topology.bats` | Cpuset expansion and formatting, and the SMT-sibling and cpuset-quota guards, behave correctly on synthetic topologies the running host may not have (`TOPO_SYSFS_ROOT`), the mechanism the fault-injection suite reuses |
| `test_jvm_pins.bats` | Flag-origin parsing tells a pinned JVM value from one that coincides with it through ergonomics |
| `test_load_testing_helpers.bats` | The helpers `lib/suite-stack.sh` (shared by `run-suite.sh` and `run-openloop.sh`) and `run-ablation.sh` each carry (cpuset counting and expansion, shuffling, compose lookups), tested from each file's own text, behave correctly; `compose_service_value` is also checked to be textually identical in both |
| `test_warmup_convergence.bats` | The gate's window spans at least 3s of each target's own traffic, so a sub-second blip is not drift while a sustained shift is; both bounds behave as documented; one lagging target, or an expected target with no data or no HTTP 200, blocks the chunk; the verdict after the last chunk is the one reported; `run-ablation.sh`'s copy of the gate is identical to the one `run-suite.sh` and `run-openloop.sh` share in `lib/suite-stack.sh` |
| `test_calibration.bats` | The iteration derivation scales inversely with concurrency, clamps at one iteration per VU, fails rather than carrying a previous target's counts forward when a calibration yields nothing, and matches `analyze-results.py`'s `(N-1)/span` in both scripts; the calibration pass prepares the stack like a rep, measures each target or cell once, and every rep reads back those counts |
| `test_thermal.bats` | Temperature and throttle counters are read from the hottest zone and in core order, `na` rather than zero where the host exposes nothing; the safety check pauses, logs the pause, and aborts only when still critical after its cooldowns; neither harness script runs against a synthetic sysfs tree |
| `test_run_layout.bats` | Run directories are named per kind and host; a new run archives only the same host's earlier run of its kind; the flat-layout sweep takes only its own kind's files; `RESULTS_DIR_OVERRIDE` archives nothing; the measurement fingerprint changes with measured code but not with tests, docs or commit state |
| `test_power_state.bats` | Turbo reads correctly through all three kernel interfaces, the power source through a mains supply or a discharging battery, and both RAPL interfaces' limits; each unprepared condition is reported, a control the host lacks is not; a changed state or lost mains supply aborts the run; `prepare-host.sh` refuses without root, sets the governor, turbo and `thermald`, and fails on battery; all four harness scripts that read the power state refuse a synthetic power tree |
| `test_orchestration.bats` | `run-all.sh`, `run-openloop.sh` and `run-predict-composition.sh` reject bad input, and a suite run without a recorded power state, before touching the stack; `composition` runs between `openloop` and `ablation`, accepts `START_AT`, and its failure does not stop the chain; the composition container is pinned to the suite's Python cpuset; the power state is checked before a run directory exists and at both edges of every measured cell; every suite cell runs under both samplers and every ablation cell under the clock sampler, stopped on both the success and the k6-failure path; the smoke test's overload cell goes through `run-openloop.sh`; `install-test-deps.sh` rebuilds a venv with no usable `bin/python` or `bin/pip` and reuses a usable one |
| `test_construct_checks.bats` | `run-openloop.sh` exports the suite run's recorded cpusets, quotas, worker count and tokens so the stack starts on them, refuses a setting the run did not record, and aborts when the resolved configuration or `JAVA_TOOL_OPTIONS` differs; startup runs the recorded-setting, topology and cpuset guards before the first rep; each rep restarts the stack and runs the suite's pin, JVM and tier checks, both gated warm-up passes (fixed-iteration only under the suite's override), the post-warm-up checks and the cooldowns, with every rate once in a per-rep shuffled order and rep-tagged file names; an abort writes one tagged line to `openloop_failures_log.txt` and none to `run_failures_log.txt`, and a new invocation archives only its own target's outputs. `run-predict-composition.sh` refuses a run without a recorded quota and a running measured stack, runs each rep in a fresh container with a shuffled tier order, the recorded cpuset and quota, a thermal check and power checks, merges the reps into schema 2, and on a failed rep logs it to `composition_failures_log.txt` and leaves no merged file; the smoke test runs one rep of each check and deletes their output; `run-all.sh` stops the stack before the composition check |
| `test_harness_libs.py` | `lib/warmup_gate.py` orders Go-trimmed timestamps numerically, sizes the window by time, reports every status and takes true medians; `lib/k6_filter.py`'s fast path keeps exactly the lines a full JSON parse would; `lib/placement.py`, on a synthetic procfs, counts connections for the uvicorn workers only (not the supervisor or its resource tracker), reports namespace PIDs, logs only changes, stops on SIGTERM and reports `placement_unavailable` rather than failing; `lib/cpufreq_sampler.py` weights each CPU's clock by its busy time, reports `na` for CPUs that never ran, and exits 3 when mains power drops, by the rule the shell applies; `lib/openloop_rates.py` derives the plateau from HTTP 200 scan completions with table 4's `(N-1)/span`; `lib/predict_composition.py` imports without XGBoost, builds the service's request frame, takes the conversion share from the medians, reads the cgroup v2 and v1 CPU limit (verified, mismatch including unlimited, or unverifiable), refuses a quota mismatch before measuring, and merges per-rep files into schema 2, refusing reps that disagree on image, workload or versions |
| `test_scan_outliers.py` | Only a rep far above its design cell is flagged, and a spread under 5% is not, whatever its z-score; a cell's placement is the state it held longest with a connection open; crowding ranks every shared worker above the even split, including `2-2-0` at four connections; uneven placements are tested against even ones at the same level; table 4g and figure 9 are written only when the run recorded placement |
| `test_analysis.py` core tests | Cell-value parsing and ordering, throughput within reps, cluster bootstrap, rank-biserial effect size, GC log parsing and k6 JSON loading |
| `test_analysis.py` table 2 test | The Java-side overhead and client-side remainder columns close the decomposition against k6's request duration |
| `test_analysis.py` table 0 tests | Table 0 judges each warm-up file with the live gate at the run's recorded parameters and keeps a row for every expected target, including ones that never converged, in both analysis scripts |
| `test_analysis.py` reservoir-sampling tests | Non-200 `http_req_duration` points are kept in full regardless of file size, so the error-count cross-check is never degraded by subsampling; a truncated gzip keeps what decompressed |
| `test_analysis.py` true-count tests | Table 1/4/7's N, extremes and throughput reflect every request seen, not the reservoir's sample, including a file whose combined point count neared the cap while no single metric did; open-loop cells at different rates for one tier stay separate |
| `test_analysis.py` thermal tests | The parser reads the trace `lib/thermal.sh` and `lib/cpufreq_sampler.py` write; throttling is attributed per service as its most-throttled CPU; each cell's clock reaches table 8a and the association, and a trace without clock lines adds no clock columns; the association is taken within design cells, so the manipulated factor cannot read as heat |
| `test_analysis.py` ablation tests | Every request outcome and dropped iteration is counted before sampling, the control value comes from the run's metadata, the planned comparison takes the value farthest from control, and a failed or empty run exits non-zero |
| `test_analysis.py` significance-floor test | `pairwise_mannwhitney` emits `[!]` when the rep count keeps even perfect separation from clearing alpha |
| `test_analysis.py` open-loop cell-identity test | A cell with zero 200 responses still gets a table 7 row with its `dropped_iterations` count, across reps too |
| `test_analysis.py` table 7 rep-level tests | P95 and P99 are taken per rep and reported as the median across reps with the range, for open- and closed-loop rows alike; dropped iterations are summed with the per-rep maximum; a single-rep file reads as one rep; entries in `openloop_failures_log.txt` mark table 7 and do not reject the run |
| `test_analysis.py` silent-success guard tests | `crosscheck_error_counters`, `analyze_measurement_floor` and `analyze_gc_logs` warn on empty or unmeasurable input rather than returning as if the check had passed |
| `test_analysis.py` table 9 tests | The conversion share and the share against the in-place baseline are recomputed from each rep's medians and summarized as the median across reps with the range; a schema-1 file reads as one rep; tiers are in order; a missing or malformed `predict_composition.json` is reported and skipped; entries in `composition_failures_log.txt` mark table 9 and do not reject the run |
| `test_host_variance.py` | Runs are found per kind and never in `archive/`; each run's outputs go to its own folder and a rejected run fails the invocation; the gate compares core counts, CPU quotas and isolation rather than CPU numbers, gates turbo, compares power limits only within a machine, and stops on any gated difference; a uniformly slower host reads as equivalent, while a target, model-computation share or ablation effect that differs reads as different; Kendall's W reports the p-value floor of identical orderings |

---

## Fault-injection guard verification

The unit tests check each guard's logic in isolation; this checks that the guards fire through the harness's real abort path. A guard that cannot fire reports a clean run exactly as a working one does.

```bash
sudo ./prepare-host.sh
cd fault-injection
./verify-guards.sh
```

- Each of the eight fault cases (`01` to `08`) misconfigures one pinned setting the suite enforces, runs a minimal slice of `run-suite.sh` against it, and records whether the expected guard rejected it.
- Case `00-unmodified` changes nothing and must pass clean, so a suite in which every case aborts is reported as a failure, not a pass.
- Everything runs against a generated copy of the compose configuration in `fault-injection/scratch/`, whose bind mounts and results directory point inside `fault-injection/`; the top-level `results/` is untouched.
- The report goes to `fault-injection/results/guard_verification_report.{md,csv}`. Like `results/`, it is host- and run-specific regenerable evidence, so it is gitignored rather than committed.

| Case | Fault | Guard |
|---|---|---|
| `00-unmodified` | Nothing changed | none, must run clean |
| `01-smt-overlap` | python-service on the other hyperthread of each of the Java service's cores: no logical CPU shared, same physical cores | `[smt]` |
| `02-cpuset-splits-core` | python-service pinned to one hyperthread of its first baseline core, leaving the sibling to the host | `[cpuset]` |
| `03-cpuset-nonexistent-cpu` | cpuset names a CPU absent on this host | `[smt]` |
| `04-cpu-quota-exceeds-cpuset` | CPU quota larger than the cpuset can supply | `[cpuset]` |
| `05-thread-limiter-drift` | Thread-limiter tokens moved off the pinned baseline | `[tier-check]` |
| `06-feature-tier-drift` | python-service loads an incomplete feature-tier set | `[tier-check]` |
| `07-gc-threads-unpinned` | GC worker-thread count left to JVM ergonomics | `[jvm-pin]` |
| `08-collector-swapped` | Collector swapped from G1 to Parallel | `[jvm-pin]` |

- **Where to run:** on the host that will produce the dataset, after `sudo ./prepare-host.sh`. Every case runs `run-suite.sh`, so the script refuses an unprepared host rather than report every case as aborting through the wrong guard.
- **SMT:** cases 01 and 02 need an SMT host and are reported as skipped, not passed, without one.
- **Baselines:** cases 01 to 04 read their baseline cpusets from `docker-compose.yml`'s defaults when those fit the host, and from `recommend-cpusets.sh` otherwise, so a case that fails because the baseline does not fit the host is distinguished from one whose guard did not fire.
- **Coverage:** config drift. Each case changes one compose-level setting and asserts a named guard rejects it. Measurement-methodology constants, such as the warm-up window or `gracefulStop`, have no abort path to assert against and are covered by the unit tests.
- **Disclosed gap:** pinned options that are present in the compose file but never reach the JVM. No compose-level fault reproduces that, so the `[jvm-pin]` guard is checked only through the flag origin the JVM reports.

---

## Reference

### API

The harness always sends the full `V1..V28` vector, whatever the tier; each endpoint slices what it needs, so one request body works against any tier.

```
POST /api/v1/transactions
Content-Type: application/json
```

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "accountId": "ACC-12345",
  "amount": 12500.50,
  "transactionType": "WIRE_TRANSFER",
  "features": [2.8, -1.2, 0.5, 1.8, -0.8, "... up to V28"],
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10
}
```

- `featureTier` selects the model. **Required** for `DISTRIBUTED_AI_SYNCHRONOUS` and ignored by mock and calibration. The accepted set is whatever `fraud-ml-service` reports at `/health`.
- `features` must contain at least `featureTier` values. It is required for every arm; mock and calibration ignore its values.
- `transactionId` must be a UUID and `accountId` must match `ACC-\d{4,10}`, validated before the AI layer. Invalid requests get a `400` with per-field errors.

Response (illustrative values for one tier-10 request at VUS 1):

```json
{
  "transactionId": "062e5e0e-398d-4e59-a29b-63175c8e345e",
  "accountId": "ACC-12345",
  "amount": 12500.50,
  "transactionType": "WIRE_TRANSFER",
  "riskScore": 0.9123,
  "transactionStatus": "FLAGGED",
  "strategy": "DISTRIBUTED_AI_SYNCHRONOUS",
  "featureTier": 10,
  "executionTimeMs": 3.05,
  "requestPreprocessingTimeMs": 0.03,
  "aiCallRoundTripTimeMs": 2.92,
  "estimatedBridgeOverheadMs": 0.62,
  "dbWriteTimeMs": 0.0,
  "responseObjectBuildTimeMs": 0.05,
  "pythonTelemetry": {
    "parsingRequestTimeMs": 0.21,
    "threadDispatchTimeMs": 0.15,
    "computationTimeMs": 1.85,
    "dataframeConstructionTimeMs": 0.20,
    "modelInferenceTimeMs": 1.60,
    "computeStallMs": 0.05,
    "serializationResponseTimeMs": 0.09,
    "totalPythonExecutionTimeMs": 2.30
  }
}
```

**Java-side fields**

| Field | Meaning |
|---|---|
| `requestPreprocessingTimeMs` | From the `RequestTimingWebFilter` stamp, taken before WebFlux dispatch, to the end of this service's request checks: WebFlux dispatch, request body decode, bean validation (`@Valid`) and this service's strategy/feature-tier cross-field checks. Named "preprocessing" because it is more than deserialization |
| `aiCallRoundTripTimeMs` | From just before the outbound request to `fraud-ml-service` is sent (`netStart`) to just after its response body is decoded. Timed inside a `Mono.defer`, so the clock starts at subscription rather than Mono assembly; the gap between building the call and WebFlux subscribing to it (handler return, the downstream `.map`, WebFlux's result-handler dispatch) is not charged to the round trip and appears only in `executionTimeMs` |
| `estimatedBridgeOverheadMs` | Computed in Java: `aiCallRoundTripTimeMs` minus Python's `totalPythonExecutionTimeMs`, unclamped. The inter-service hop over the Docker bridge both ways, plus Jackson encoding and decoding, uvicorn's HTTP parsing and writing, any queueing before P0, the serialization estimate's error, and a TCP connect on each cell's first requests. FastAPI routing is not included; it falls in `parsingRequestTimeMs`. Not a real network hop ([Threats to validity](#threats-to-validity)) |
| `dbWriteTimeMs` | `0.0` when `APP_DB_SAVE_ENABLED=false`, which benchmarks require |
| `responseObjectBuildTimeMs` | Time to assemble the final `ResponseDto` |
| `executionTimeMs` | Java-side duration from the `RequestTimingWebFilter` stamp to the start of response assembly: WebFlux dispatch, validation, the AI call and the gap before it. Excludes Netty's read before the stamp, building the `ResponseDto`, and encoding and writing the response, which only k6's `http_req_duration` sees (table 2's client-side remainder) |

**Python-side fields (`pythonTelemetry`)**

| Field | Meaning |
|---|---|
| `parsingRequestTimeMs` | From the `TimingMiddleware` stamp (P0, the outermost application middleware) to the handler: FastAPI routing, body read and Pydantic validation. uvicorn's own HTTP parsing happens before the stamp and is not included |
| `threadDispatchTimeMs` | The `run_in_threadpool` call minus the work's own computation time: waiting for a limiter token, handing the call to a worker thread, that thread acquiring the GIL, and the result returning to the event loop. Floored at 0; measured for all three arms. For `mock`, the random draw runs in the worker thread and reports no computation, so its cost lands here |
| `computationTimeMs` | The whole worker-thread window: validation, the `log1p` transform, row build, DataFrame construction, inference and threshold comparison. A superset of `dataframeConstructionTimeMs` plus `modelInferenceTimeMs`; `0.0` for mock and calibration |
| `dataframeConstructionTimeMs` | The `pd.DataFrame()` call only. XGBoost's later ingestion of that frame counts in `modelInferenceTimeMs` |
| `modelInferenceTimeMs` | The complete `predict_proba` call: XGBoost's per-call conversion of the DataFrame (in-place prediction path), feature-name validation and booster tree traversal ([Threats to validity](#threats-to-validity) covers what dominates it; table 9 measures the split) |
| `computeStallMs` | Computation wall time minus the thread's CPU time: the part of computation the thread was off-CPU (GIL or OS scheduling). A subset of `computationTimeMs`, floored at 0 |
| `serializationResponseTimeMs` | Estimated response-serialization cost |
| `totalPythonExecutionTimeMs` | From the `TimingMiddleware` stamp to just before serialization, plus the serialization estimate. Excludes uvicorn's HTTP parsing and writing |

`serializationResponseTimeMs` and `totalPythonExecutionTimeMs` are estimates: a response cannot report the cost of serializing itself without a prior serialization pass.

### Dataset and models

- Source: the [Kaggle Credit Card Fraud dataset](https://www.kaggle.com/mlg-ulb/creditcardfraud), anonymized European transactions, September 2013.
- Each tier uses the first `n` of the 28 `V` PCA components (`V1..Vn`) plus `Amount` (`log1p`-transformed). `V10` is a strict superset of `V5`, and so on.
- About 0.17% fraud. Each tier is trained independently, with SMOTE oversampling and then `XGBClassifier`.
- Pretrained models for all four tiers are committed under `services/fraud-ml-service/models/`, so `docker compose up` needs no training step.
- `creditcard.csv` is not bundled (Kaggle license). To retrain, place it at `services/fraud-ml-service/training/data/creditcard.csv`, or pass `--synthetic` for a structural smoke test only.
- The Python service loads the tiers listed in `FEATURE_TIERS` (default `5,10,20,28`) and refuses to start if a listed tier's `.joblib` is missing.

```bash
training/train_model.py --n-features {5,10,20,28}   # one tier
# omit the flag to train all four → models/fraud_model_v{n}.joblib
```

### Containers and hardware

| | python-service | transaction-service | k6 (load generator) |
|---|---|---|---|
| Image | `python:3.11-slim` (pinned by digest) | build `eclipse-temurin:21.0.12_8-jdk-alpine`, run `21.0.12_8-jre-alpine` (both pinned by digest) | `grafana/k6:0.54.0` (pinned) |
| Port | `8000` | `8080` | n/a |
| Cores (`cpuset`) | `0-1,4-5,8-9` (physical 0, 2, 4) | `2-3,6-7` (physical 1, 3) | `10-11,14-15` (physical 5, 7) |
| Limit / reserved | 6.0 CPU / 3 GiB RAM (1 GiB reserved) | 4.0 CPU / 3 GiB RAM (1 GiB reserved) | 4.0 CPU / 1 GiB RAM |

- **Reproducible builds:** the service base images are pinned by digest, and python-service installs `requirements.lock` (every direct and transitive package at an exact version) rather than resolving `requirements.txt`, so a rebuild reproduces the measured images.
- **python-service:** `UVICORN_WORKERS=3` and `THREAD_LIMITER_TOKENS=40` at benchmark time. `n_jobs=1` and the BLAS variables keep each `predict_proba` call single-threaded, independent of the three workers.
- **transaction-service:**
  - The outbound pool to Python is sized by `python.service.max-connections` (default `128`, set by the harness through `PYTHON_SERVICE_MAX_CONNECTIONS`). It must stay at or above the highest VUS in `run-suite.sh`'s `CONCURRENCY_LEVELS` (`64`), or queueing inflates `estimatedBridgeOverheadMs`. `python.service.pending-acquire-timeout-ms` (default `5000`) bounds the wait.
  - The feature-tier set is fetched from Python's `/health` at startup, retrying for up to 60s.
  - The heap is fixed at 1536 MiB (`JAVA_TOOL_OPTIONS=-Xms1536m -Xmx1536m`), for the same sizing across hosts and reps.
- **k6:** runs in its own container on a disjoint cpuset, behind the `loadgen` Compose profile. The harness starts it per cell with `docker compose run`; `docker compose up` does not. Its tag is pinned because it is the only image not built from this tree, and `run_metadata.json` records the resolved digest.
- Resource limits (`mem_limit`, `mem_reservation`, `cpus`) use Compose's plain top-level keys rather than `deploy.resources.limits`, a Swarm-only directive that `docker compose up` does not enforce.

---

## Structure

```
.
├── docker-compose.yml
├── setup.sh                       # once per machine: .env (HOST_UID/GID), results/gc-logs/, analysis/venv
├── install-test-deps.sh           # once per machine: every *test* toolchain below, in one pass
├── prepare-host.sh                # before every run (sudo): governor, turbo, thermald
├── analysis/
│   ├── analyze-results.py        # tables, figures, significance tests, per suite run
│   ├── analyze-ablation.py       # thread-dispatch mechanism sweep, per ablation run
│   ├── analyze-host-variance.py            # suite runs compared across hosts
│   ├── analyze-ablation-host-variance.py   # ablation runs compared across hosts
│   ├── lib/
│   │   ├── warmup_check.py       # table 0 for both scripts, judged by load-testing/lib/warmup_gate.py
│   │   ├── thermal.py            # per-cell thermal state, pauses, thermal-latency association
│   │   ├── scan_outliers.py      # scan outlier cells and latency by connection-to-worker placement
│   │   ├── run_dirs.py           # run-directory discovery and identity, output folders
│   │   ├── report.py             # table (.csv/.md/.tex) and figure (.png/.pdf) writers
│   │   └── hostvariance.py       # environment gate and cross-run statistics
│   ├── probing/
│   │   └── plot_warmup_curve.py  # thermal diagnostic: latency vs VUs, temp and core frequency
│   ├── output/                   # generated: tables/<run>/, figures/<run>/, hostvariance/{tables,figures}/
│   ├── tests/                    # pytest (215): analysis pipeline, harness libraries, thermal, outliers, host variance
│   ├── requirements.txt
│   └── requirements-dev.txt      # test-only: pytest, kept off analyze-*.py's real runtime deps
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── run-ablation.sh           # four-arm thread-dispatch mechanism sweep
│   ├── run-openloop.sh           # open-loop validity check against one suite run
│   ├── run-predict-composition.sh  # predict_proba conversion vs traversal split against one suite run
│   ├── run-all.sh                # suite, open-loop and composition checks, ablation and both analyses in sequence
│   ├── run-smoke-test.sh         # small pipeline-check pass before the full suite
│   ├── recommend-cpusets.sh      # prints cpuset values fitting this host's topology
│   ├── warm-up.js                # per-target sequential JIT/pool warm-up
│   ├── run-target.js             # single (target, concurrency, rep) cell runner (closed-loop)
│   ├── run-target-openloop.js    # constant-arrival-rate cell runner, driven by run-openloop.sh
│   ├── lib/
│   │   ├── common.js             # shared sendTransaction()/TARGETS + telemetry Trends
│   │   ├── topology.sh           # cpuset to physical-core resolution; SMT-overlap/cpuset-quota guards
│   │   ├── jvm-pins.sh           # verifies G1/thread-pool ceilings against the JVM's own flag origin
│   │   ├── host-provenance.sh    # isolcpus/power-source/irqbalance/virtualization sampling for run_metadata.json
│   │   ├── power-state.sh        # CPU power state: start-of-run requirement, per-cell re-check, metadata
│   │   ├── run-layout.sh         # per-run results directory, archiving, measurement fingerprint
│   │   ├── suite-stack.sh        # restarts, per-rep guards, warm-up gate, cell wrapper: run-suite.sh and run-openloop.sh
│   │   ├── thermal.sh            # thermal guard, per-cell temperature and throttle telemetry
│   │   ├── warmup_gate.py        # warm-up convergence criterion shared by the gate, probes and table 0
│   │   ├── placement.py          # per-cell connection-to-worker placement, read from the host's procfs
│   │   ├── openloop_rates.py     # a suite run's plateau throughput, for run-openloop.sh's rates
│   │   ├── cpufreq_sampler.py    # per-cell service-core clock and mains-power loss
│   │   ├── predict_composition.py  # in-image predict_proba timing for run-predict-composition.sh
│   │   └── k6_filter.py          # keeps the metrics the analysis reads and gzips each result
│   ├── probing/                  # standalone diagnostics, not wired into the suite
│   │   ├── probe_warmup_joint.sh         # all six targets, past the chunk cap, per-target tail drift
│   │   ├── probe_warmup_settle.sh        # one target, past the cap, widenable criterion
│   │   ├── calibrate_scan_iterations.sh  # per-host ITERATIONS_PER_VU derivation
│   │   ├── probe_calibration_drift.sh    # checks calibration-pass throughput holds across reps
│   │   ├── probe_ablation_taper.sh       # per-arm cell-duration check
│   │   └── probe_telemetry_completeness.sh  # per-target telemetry field presence, build-freshness check
│   └── tests/                    # bats-core (173): topology, JVM pins, shared helpers, warm-up gate, calibration, thermal, power state, run layout, orchestration, construct-validity checks
├── fault-injection/
│   ├── verify-guards.sh          # runs each case, records whether the expected guard fired
│   ├── cases/*.case              # 9 cases: 00 unmodified as control, 01-08 each misconfigure one pinned setting
│   └── results/guard_verification_report.{md,csv}
├── results/                       # generated, gitignored except .gitkeep
│   ├── suite_<host>_<timestamp>/  # one run-suite.sh run: *.json.gz, run_metadata.json, logs, gc-logs/
│   ├── ablation_<host>_<timestamp>/  # one run-ablation.sh run: ablation_* files
│   ├── logs/run-all_<timestamp>/  # run-all.sh's per-step console output
│   └── archive/                   # superseded runs of the same kind and host
└── services/
    ├── fraud-ml-service/            # Python FastAPI inference service
    │   ├── app/
    │   │   ├── main.py              # entrypoint, TimingMiddleware, /health
    │   │   ├── model.py             # FraudModelRegistry: one FraudMLTier per tier
    │   │   ├── config.py            # FEATURE_TIERS, MODEL_DIR, numeric thread env
    │   │   ├── schemas.py
    │   │   ├── responses.py         # shared response/telemetry builder
    │   │   └── routers/predict.py (POST /predict/v{n}), mock.py, calibration.py
    │   ├── tests/                   # pytest (63): timing invariants, EWMA, telemetry symmetry, library contracts
    │   ├── requirements.txt         # direct dependencies
    │   ├── requirements.lock        # full pinned environment the image installs
    │   ├── requirements-dev.txt     # test-only deps, kept out of the service image
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/
            ├── main/java/.../{config,controller,service,model,repository,dto,exception,filter}/
            └── test/java/.../       # JUnit (37): overhead derivation, routing, upstream error mapping, timing filter
```

---

## Troubleshooting

- **`permission denied` writing `/results/*.json` or `/gc-logs/*` from inside a container.** `./setup.sh` was not run, or its `.env` predates a fresh clone, so bind-mounted directories are owned by root or another UID ([Setup](#1-setup-once-per-machine)). Run `./setup.sh`, confirm `.env` matches `id -u`/`id -g`, and retry. If `results/` was created root-owned before `setup.sh` ran, reclaim it once with `sudo chown -R $(id -u):$(id -g) results/`.
- **`Permission denied` running `./setup.sh` or a harness script.** The executable bit was lost. `git clone` keeps it; GitHub's "Download ZIP" and some Windows-side transfers strip it. Fix once: `chmod +x setup.sh prepare-host.sh install-test-deps.sh load-testing/*.sh load-testing/probing/*.sh fault-injection/*.sh`.
- **`Conflict. The container name "/..." is already in use`** on `docker compose up`. Stopped containers from an interrupted run, or from another clone of this repo, hold the name, since `container_name` is fixed (`python`/`java`) rather than project-scoped. Run `docker rm -f python java`, then retry.
- **The run pauses for a minute or more, or aborts with a `[thermal]` message.** The thermal guard found a zone at or above 90C after a cell or warm-up chunk and is cooling down; it aborts if still at or above 95C when the pausing stops ([Measurement controls](#measurement-controls)). On a laptop this is the common cause of a long run stopping on its own. `env_trace_log.txt` has the temperature and throttle counters around every cell and pause; table 8b totals the pause time per phase.
- **A harness script refuses to start: "This host is not in the power state a measurement run requires".** The lines under it name each unmet condition. Run `sudo ./prepare-host.sh` from the repository root, connect the charger if it reports battery power, and start again. The settings reset on every reboot.
- **A run aborts with a `[power]` entry in its failures log.** The power state changed mid-run; the entry shows the state at the start and at the failed check. An unplugged charger is the usual cause, a firmware power-limit change the other. The analysis rejects the run; prepare the host and start a new one.
- **Throughput far below an earlier run's on the same machine.** Compare `power_state.power_limits` in the two runs' metadata. Booting on battery can leave the firmware's power limits reduced after the charger is connected, until a reboot with the charger in. The host-variance gate reports this as a mismatch between runs of one machine.
- **`error: externally-managed-environment` from `pip install`.** Ubuntu 24.04+ (PEP 668) refuses a bare `pip install` against the system Python. Use `analysis/venv/bin/python3` or its `pip`, which `./setup.sh` creates, rather than the `python3`/`pip3` on `PATH`.
- **`pip install` fails building from source inside `analysis/venv`.** No prebuilt wheel exists for this Python version at these floors, most likely on very new or very old CPython. Run `analysis/venv/bin/pip install --upgrade pip` first; if the source build still fails, install without version constraints (`analysis/venv/bin/pip install pandas numpy matplotlib scipy tabulate statsmodels jinja2`), since the analysis is not sensitive to exact versions of these.
- **Docker or Compose issues in general** (daemon unreachable, `docker compose` vs. `docker-compose`, WSL2 PATH quirks) are environment setup outside this project. If `docker info` fails, consult Docker's documentation for your OS first.

---

## Credits

- Transaction orchestrator originally by [MuhammadHussain06](https://github.com/MuhammadHussain06/fraud-eval-harness).
- The original barebones Python inference service, which `fraud-ml-service` extends, by Mohamad Naim bin Salleh ([MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice)).
- Containerization, mock/calibration routing, load testing, and telemetry/concurrency work by [MuhammadHussain06](https://github.com/MuhammadHussain06), integrating and extending both.
