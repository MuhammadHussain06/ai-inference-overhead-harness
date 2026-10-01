# AI Inference Overhead Harness

A containerized testbed that measures the **latency and throughput cost of a live AI fraud-inference call**, against a network-equivalent mock and a zero-work calibration floor.

```bash
./setup.sh                        # once per machine
docker compose build              # build both service images
sudo ./prepare-host.sh            # before every run: the CPU power state (turbo off)
./load-testing/run-all.sh         # suite, open-loop check, ablation, then both analyses
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

Every transaction is scored by one of three strategies, selected per request by `strategy`. All three share the same JVM, DTOs and network hop: Java's WebClient calls `fraud-ml-service` over HTTP in every case.

| Strategy | Target | Work in Python | Purpose |
|---|---|---|---|
| `DISTRIBUTED_AI_SYNCHRONOUS` | `5`, `10`, `20`, `28` | XGBoost model for the feature-count tier in `featureTier` (`V5`/`V10`/`V20`/`V28`), routed to `/predict/v{tier}` | Actual inference cost |
| `DISTRIBUTED_MOCK_GATEWAY` | `mock` | One random draw; same request/response shape and path | Network-equivalent baseline |
| `DISTRIBUTED_CALIBRATION_ONLY` | `calibration` | None, not even a random draw | Instrumentation floor |

Latency is attributed by subtraction, since each pair of strategies differs in one layer:

- `calibration` traverses every layer the AI path does (parsing, thread dispatch, serialization, the network hop) with no work behind it, bounding the framework and transport floor.
- **Mock − calibration** ≈ the cost of one random draw.
- **AI tier − calibration** ≈ DataFrame construction plus model inference.
- `test_api.py` asserts all three strategies emit structurally identical telemetry, the precondition for the subtraction.

Each tier is its own XGBoost model, loaded once at startup and held in memory. DB persistence is off for every benchmark run (`APP_DB_SAVE_ENABLED=false`), so writes never enter the measured path, and H2 is in memory, so every run starts clean.

### Research questions

| | Question | Answered by |
|---|---|---|
| **RQ1** | In a synchronous microservice call, how does end-to-end latency decompose across model inference, DataFrame construction, thread dispatch, framework overhead and the network hop? | E1 baseline (`run-suite.sh`); tables 1 to 3, figures 1 to 2 |
| **RQ2** | How does that decomposition shift with model complexity (feature-count tier) and request concurrency? | E1 across tiers, E2 concurrency scan; tables 4 to 6, figures 3 to 5 |
| **RQ3** | Which mechanism drives the thread-dispatch cost that dominates at high concurrency: thread-limiter capacity, available cores, or process count (GIL)? | [Ablation](#ablation-rq3) (`run-ablation.sh`, `analyze-ablation.py`), four arms |
| **RQ4** | Do the ratios behind RQ1 to RQ3 reproduce across repetitions and hosts? | Per-ratio equivalence tests between runs, after an environment gate ([Cross-host comparison](#cross-host-comparison)) |

### Scope

**Answers**, for a synchronous, single-node, single-request microservice call with turbo off:

- how much of end-to-end latency is model compute versus everything else (network, framework, serialization, queueing);
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
  - `load-testing/recommend-cpusets.sh` picks values for this host: it reads the topology, uses performance cores only on a hybrid CPU, and prints `export` lines for `PYTHON_CPUSET`, `JAVA_CPUSET`, `K6_CPUSET` and the ablation's narrow and wide cpusets, pre-checked against the suite's guard. It only recommends: review the output, `export` it, then run.
  - To inspect the topology by hand: `cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list`.
- About 7 GB of free RAM. No GPU.
- `sudo`, for `prepare-host.sh` before every run.
- Python 3 on the host. `run-suite.sh` uses it for tier verification; the analysis needs `analysis/requirements.txt` (pandas, numpy, matplotlib, scipy, statsmodels, tabulate, jinja2), which `setup.sh` installs into `analysis/venv/`.
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

A control the host does not expose, such as cpufreq in most VMs or a battery on a desktop, is recorded as `unexposed` rather than required. The state is re-checked throughout the run ([Measurement controls](#measurement-controls)), and `run-openloop.sh` also refuses a state that differs from the one its suite run recorded.

### 3. Smoke test (before the full suite)

```bash
sudo ./prepare-host.sh
docker compose up -d
cd load-testing
./run-smoke-test.sh
```

Runs every path the full design depends on at small scale, catching a structural problem (bad config, broken tag, mislabeled tier) in minutes:

- a suite slice: 2 targets, 2 concurrency levels, 2 reps, reduced iteration counts;
- a deliberately unsustainable 20s open-loop cell at `RATE=5000`, to confirm `dropped_iterations` is detected;
- a two-cell slice of the ablation's `cpuset` arm, whose values are cpuset strings rather than integers;
- **both** analysis scripts.

It ends with a checklist for the two run directories it names:

- failures logs empty; cpu-pin logs clean, including the `smt_check` lines;
- env trace logs with `cell_start`/`cell_end`, `cell_freq` and `thermal_check` lines for every cell; both calibration logs filled;
- `power_state` in both metadata files as `prepare-host.sh` set it;
- `placement` lines for every cell, not `placement_unavailable`;
- a nonzero `dropped_iterations` count on the printed `[+] smoke-openloop:` line;
- both cpuset values in `table_ablation_decomposition`, ordered by core count.

Expected on a smoke run:

- Table 7 omits the overload cell (`phase=smoke-openloop` is excluded by design); the script checks that cell's file directly.
- Both table 0s list every target as `fewer than three windows`: the gate needs three windows of at least 500 requests, and the slice sends about 20 per target.
- The ablation tables carry no meaningful statistics at 2 reps; they only need to render.
- The smoke runs are ordinary runs: they archive this machine's previous suite and ablation runs, and `analysis/output/` then holds only the two smoke runs.

A clean smoke test shows the pipeline works, not that any rep count is sufficient. Re-run it after any fix until it passes.

### 4. Everything in one run

`run-all.sh` runs `run-suite.sh`, `run-openloop.sh` against that suite run, `run-ablation.sh`, then `analyze-results.py` and `analyze-ablation.py` on the two runs it produced.

- It checks the power state before the first step and records the state, or the refusal, in `run-all.log`.
- Each step's output goes to `results/logs/run-all_<UTC timestamp>/`, with one line per step in `run-all.log`.
- A failed suite stops the chain. A failed open-loop check or ablation is reported and the remaining steps still run. The exit status is non-zero if any step failed.
- `START_AT=openloop`, `ablation` or `analysis` resumes at that step against this host's latest runs.

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
2. **Calibration**, once: derive each target's scan iteration counts ([Experimental design rationale](#experimental-design-rationale)).
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
- **Calibration:** each cell is throughput-calibrated once, in a pass before the reps that restarts the stack at that cell's configuration and warms it up as its reps will; every rep of the cell runs that count.
- **Controls:** every cell gets the suite's warm-up gate, pin verification, power-state checks, thermal and clock telemetry, and abort-on-invalid behavior.
- **Planned comparison** (`table_ablation_control_vs_extreme`): per arm, the control value recorded in `ablation_run_metadata.json` against the sweep value farthest from it (by logical CPUs for a cpuset), the arm's largest manipulation. The control sits at an end of the sweep for `thread_limiter` and `workers`, and inside it for `cpuset`, where 2 CPUs is farther from the 6-CPU control than 8. `workers_token_matched` compares its two values directly.

#### Open-loop validity check

The suite's concurrency scan is closed-loop. `run-target-openloop.js` runs the same target under k6's `constant-arrival-rate` executor, firing on a fixed schedule regardless of response time, the standard mitigation for coordinated omission. `run-all.sh` runs it after the suite.

```bash
cd load-testing
./run-openloop.sh                                   # this host's latest suite run
./run-openloop.sh ../results/suite_<host>_<timestamp>
```

- **Rates:** fractions (`OPENLOOP_FRACTIONS`, default `1.0 0.8`) of the target's closed-loop throughput at the run's highest scan concurrency (`lib/openloop_rates.py`, table 4's convention): at the plateau, where an open arrival process meets a saturated service, and below it. `OPENLOOP_RATES` sets explicit requests per second instead.
- **Cells:** `OPENLOOP_DURATION` (`2m`) each, with `OPENLOOP_PRE_ALLOCATED_VUS` (64) and `OPENLOOP_MAX_VUS` (128), on a freshly restarted stack warmed up at the target, under the suite's thermal guard. `OPENLOOP_TARGET` (28) and `OPENLOOP_PHASE` are overridable.
- **`dropped_iterations`:** k6 emits it when `MAX_VUS` cannot sustain the rate, i.e. the service cannot absorb that arrival rate.
- **Analysis:** when `openloop_*` files are present, `analyze-results.py` adds table 7 and figure 7, comparing open-loop P95/P99 with the closed-loop scan at the top two scanned concurrency levels for the same tier; without them the step is skipped and the rest of the analysis is unaffected. Table 7 is grouped by tier *and* `RATE`, so cells at different rates are never pooled, and always excludes the smoke test's `phase=smoke-openloop` cell.

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
| `run-suite.sh`, `run-ablation.sh`, `run-all.sh`, `verify-guards.sh` | `REQUIRED_TURBO_OVERRIDE` (`on` or `off`, default `off`); `run-openloop.sh` requires the turbo its suite run recorded |

- `ABLATION_ITERATIONS_PER_VU_OVERRIDE` only sets a metadata fallback: a measured cell's count always comes from calibration, so the two `ABLATION_CALIB_*_OVERRIDE` variables are what shrink an ablation slice.
- `run-smoke-test.sh` sets both scripts' variables to a small slice. Unset, each script runs its full default design.

---

## Outputs

### Run directories

- Each `run-suite.sh` or `run-ablation.sh` invocation writes one run directory, `results/<kind>_<host>_<UTC timestamp>/`. `<kind>` is `suite` or `ablation`; `<host>` is the hostname, lowercased and reduced to `[a-z0-9.-]`.
- Starting a run moves this machine's previous run of the same kind to `results/archive/`. Runs of the other kind, and runs copied in from other machines, stay in place.
- A machine is its hostname plus a hash of its machine ID, so a copied run from a same-named host is not archived. Give each host a distinct hostname anyway, since the hostname labels its runs in every table.
- Result files that the flat layout used before v1.2 left directly in `results/` move to `results/archive/<timestamp>/` (`<timestamp>_ablation/` for the ablation's) on the next run of their kind.
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
- **Toolchain and code:** Docker and Compose versions, k6 image digest, git commit and dirty flag, and the measurement fingerprint: a SHA-256 over the tracked files that shape a measurement (the compose file, both services and the load-testing harness, excluding tests, probes and model training).
- **Host:** CPU and RAM, CPU governor and frequency snapshot, and host provenance: `isolcpus` live state and boot cmdline, AC/battery power source, `irqbalance` status, virtualization as reported by `systemd-detect-virt`, `wsl2_detected` and `physical_core_isolation`.
- **Power state** (`power_state`), the state every cell is checked against: power source, turbo and the turbo the run required, governor, energy preference, power profile, `thermald`, and the sustained and short-term package power limits from both RAPL interfaces (MSR and MMIO).
- **Services:** each service's cpuset, CPU quota and physical cores.
- **Configuration:** the run configuration, including uvicorn workers and thread-limiter tokens.

### Other run output

- **`run-openloop.sh`** adds to the suite run it checks: `openloop_<target>_rate<R>.json.gz` per rate, `openloop_log.txt` (target, plateau, fractions and rates of each invocation), `openloop_env_trace_log.txt` (its per-cell thermal and clock samples) and `gc-logs/gc_openloop_<timestamp>.log`.
- **`run-ablation.sh`** writes the same shapes into `results/ablation_<host>_<timestamp>/` under `ablation_` prefixes: `ablation_<arm>_<value>_rep<N>.json.gz`, `ablation_warmup_*`, `ablation_calib_*` (the calibration pass's measurement and warm-up per cell), `ablation_calibration_log.txt`, `ablation_run_order_log.txt`, `ablation_run_metadata.json` (the same host and toolchain fields as `run_metadata.json`, plus each arm's control value), `ablation_cpu_pin_check_log.txt`, `ablation_env_trace_log.txt` and `ablation_run_failures_log.txt`.
- **`run-all.sh`** writes each step's console output to `results/logs/run-all_<timestamp>/`: `run-all.log` (one line per step), `suite.log`, `openloop.log`, `ablation.log`, `analysis_suite.log` and `analysis_ablation.log`. The analysis scripts never read `logs/`.
- **k6 results are filtered before storage.** k6 writes its full output to the run directory's `raw/`; `finalize_result()` keeps only the metrics the analysis reads (`KEEP_METRICS`), gzips the result into the run directory and deletes the raw copy. `raw/` is removed once the run completes.
  - `KEEP_METRICS` includes `request_http_error` and `request_timeout_error`, for `crosscheck_error_counters()`'s independent error count, and `java_execution_time_ms`, the Java-side total.
  - The filter (`lib/k6_filter.py`) reads each line's metric name from k6's fixed JSON prefix, with a full parse for any line not in that shape.

### Analysis output

- `analyze-results.py` and `analyze-ablation.py` analyze every run of their kind under `--results-dir` (default `results/`, excluding `archive/`); the option also takes one or more run directories. A pre-v1.2 `results/` holding result files directly is analyzed as one run.
- Each run's output goes to `analysis/output/tables/<run>/` and `analysis/output/figures/<run>/`, named after its run directory, each table as `.csv`, `.md` and `.tex`.
- Every invocation first removes all output folders of its kind, so `analysis/output/` holds exactly the runs last analyzed.
- A run with entries in its failures log is reported and skipped, and the script exits non-zero.

Statistics: P50/P95/P99 and latency histograms per strategy and tier, Mann-Whitney U tests (Holm-Bonferroni corrected, rank-biserial effect sizes), cluster bootstrap CIs over reps, and CoV% across reps for reproducibility.

| | |
|---|---|
| Main suite | `table0_warmup_convergence_check`, `table1_baseline_e2e_latency_pooled`, `table1b_baseline_between_run_consistency`, `table1c_baseline_error_rates`, `table1d_baseline_client_diagnostics`, `table1e_measurement_floor_violations`, `table2_baseline_python_decomposition_mean_ms`, `table3_dataframe_share_of_computation`, `table4_concurrency_scan_summary_pooled`, `table4b_scan_between_run_consistency`, `table4c_scan_error_rates`, `table4d_scan_client_diagnostics`, `table4e_scan_within_cell_drift`, `table5_baseline_adjacent_tier_significance`, `table6_scan_adjacent_concurrency_significance`, `table_gc_overhead`, `table8a_thermal_by_group`, `table8b_thermal_pauses`, `table8c_thermal_latency_association`, `table4f_scan_outlier_cells` when any scan cell is flagged, `table4g_scan_connection_placement` when the run recorded placement, and `table7_openloop_validity_check` when open-loop files are present |
| Figures | `figure1_baseline_decomposition_stacked_bar`, `figure2_baseline_latency_distribution`, `figure3_p95_latency_vs_concurrency`, `figure4_throughput_vs_concurrency`, `figure5_decomposition_vs_concurrency_v<tier>`, `figure6_between_run_reproducibility_baseline`, `fig_gc_overhead`, `figure8_thermal_timeline`, and `figure7_openloop_validity_check` and `figure9_scan_connection_placement` when applicable |
| Ablation | `table0_ablation_warmup_convergence_check`, `table_ablation_error_rates`, `table_ablation_decomposition`, `table_ablation_control_agreement`, `table_ablation_control_vs_extreme`, `table_ablation_thermal_by_cell`, `table_ablation_thermal_pauses`, `table_ablation_thermal_association`, `figure_ablation_mechanisms`, `figure_ablation_thermal_timeline` |

Tables that report the run's own conditions:

| Table | Reads as |
|---|---|
| `table0*` | One row per warm-up pass and target, including targets that never reached three windows or never returned HTTP 200, with the gate's status. `no`: the target entered its measured phase still moving |
| `table4_concurrency_scan_summary_pooled` | The `Sampling` column explains why N jumps by orders of magnitude between rows: `Iteration-based` levels run a fixed count per virtual user; `Duration-calibrated` levels (`CALIB_AFFECTED_LEVELS`, from the run's `run_metadata.json`) run to a fixed wall-clock target, producing far more requests at the same VUS |
| `table4e_scan_within_cell_drift` | Mean change from the first to the second half of each scan cell, with a t-interval across reps. The same sign in every rep means the cell mean depends on its duration, which calibration holds near 60s at VUS 8 and above |
| `table4f_scan_outlier_cells` | Scan cells whose mean latency sits far above their design cell's other reps: modified z-score above 3.5 and at least 5% above the median rep. A median shift as large as the deviation: the whole cell moved, not just its start. Compute stall above the other reps': Python threads waited off-CPU. `Placement`: connections per python-service worker, busiest first. `Python clock`: its service-core clock |
| `table4g_scan_connection_placement`, `figure9_scan_connection_placement` | Scan cells per concurrency level, grouped by crowding above the even split. Crowding is the number of connections on the worker serving a connection, itself included, averaged over connections (sum of squared per-worker counts over the total); the most even split has the lowest. Per group: latency deviation, extra compute stall, and a Mann-Whitney test against the even cells, cells as units. Uneven cells running slower with raised compute stall: that level's between-rep spread follows placement |
| `table8a_thermal_by_group`, `table_ablation_thermal_by_cell` | Per design group: temperature at both cell edges, whether any service's cores were throttled, and each service's median CPU clock. `not exposed`: the host publishes no throttle counters, so throttling is unmeasured, not absent. In loaded cells, a clock below the group's usual value marks cells that ran on slower hardware, whatever their latency; at light load the reading runs low ([Measurement controls](#measurement-controls)) |
| `table8b_thermal_pauses`, `table_ablation_thermal_pauses` | How often each phase paused for heat, and the wall-clock minutes it cost |
| `table8c_thermal_latency_association`, `table_ablation_thermal_association` | Spearman correlation of a cell's temperature, throttling or service-core clock with its latency, as the deviation from its design cell's mean across reps so the manipulated factor cannot register as heat. Near zero: thermal state does not explain the between-rep spread |
| `table_ablation_error_rates` | Every ablation request's outcome and the iterations k6 dropped, counted before sampling, since the ablation's latency tables cover HTTP 200s only |

---

## Measurement controls

Conditions that invalidate a measurement abort the run; conditions with no single correct value are recorded.

### Enforced

An abort (`abort_suite`) stops the run at once and writes a tagged entry to `run_failures_log.txt`. No results are written for that rep, earlier reps on disk are unaffected, and `analyze-results.py` rejects any run whose failures log has entries, so there are no partial runs.

- **CPU pinning, every rep.** A `cpuset` in `docker-compose.yml` is a request, not proof of what the cgroup applied. The requested cpuset (`docker inspect --format '{{.HostConfig.CpusetCpus}}'`) is compared with the live one (`docker exec <container> cat /sys/fs/cgroup/cpuset.cpus.effective`, cgroup v2 with a v1 fallback) and logged in `cpu_pin_check_log.txt`. A live cpuset the cgroup does not expose is logged as `WARN_SKIPPED`, not a mismatch, and `analyze-results.py` reports the count.
- **Physical-core isolation, before any container starts.** `verify_smt_isolation()` resolves each cpuset to physical cores through `thread_siblings_list` and aborts if python, java and k6 share cores through SMT siblings; disjoint cpusets do not imply disjoint hardware.
- **Single-threaded inference.** `n_jobs=1` is read back at model load and after real inference (`nJobsVerified` / `nJobsRuntimeVerified` on `/health`). `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS` and `NUMEXPR_NUM_THREADS` are pinned to 1 and asserted from `/health` every rep, since `n_jobs` does not constrain the BLAS layer.
- **Feature tiers and thread limiter, every rep.** `/health` must report `loadedTiers` of `5,10,20,28` (python-service loads every `FEATURE_TIERS` entry on start, whichever targets the run uses), `nJobsVerified` true for every tier, and the pinned thread-limiter token count. This catches a silent tier-load failure, which would corrupt AI-tier cells without any request-level error.
  - `THREAD_LIMITER_TOKENS` (default `40`) sets anyio's limiter capacity as an explicit parameter rather than the library default.
  - Java fetches the tier set from `/health` at startup; it is never hardcoded.
- **JVM pins, every rep.** At rep start, G1 and its worker-thread ceilings are read back with `-XX:+PrintFlagsFinal` (`lib/jvm-pins.sh`), including each flag's *origin*, which separates a value the compose file set from one that coincides through JVM ergonomics. The Reactor Netty event-loop count is a system property, absent from that dump, so after warm-up, once every event loop has served traffic, a `/proc` thread census counts live GC and event-loop threads against their ceilings.
- **CPU power state, every rep and both edges of every measured cell** (`lib/power-state.sh`). Start requirements: [Prepare the host](#2-prepare-the-host-before-every-run). Any change, e.g. an unplugged charger or a firmware power-limit change, aborts with a `[power]` entry. `lib/cpufreq_sampler.py` also aborts a cell during which mains power was lost.
- **Heat, after every cell and warm-up chunk** (`lib/thermal.sh`), from every readable `thermal_zone*`:
  - at or above `THERMAL_WARN_C` (90C): pause `THERMAL_COOLDOWN_S` (60s) and check again;
  - `MAX_THERMAL_COOLDOWNS` (2) rounds always, then more while each is colder than the last, up to `THERMAL_MAX_COOLDOWNS_EXTENDED` (10) in total;
  - still at or above `THERMAL_CRIT_C` (95C) when the pausing stops: abort;
  - every check is logged with its pause, so the run's thermal cost is measured rather than absorbed into the numbers.
- **Cell failures.** A failed k6 run, an OOM kill or a readiness timeout aborts the run. Request-level errors inside a completed cell (non-200 responses, timeouts) do not: tables 1c and 4c count them, and every latency table covers HTTP 200 requests only.

### Fixed by configuration

- **Outbound connection pool:** both harness scripts size Java's pool to Python at 2x the run's peak VUS (`PYTHON_SERVICE_MAX_CONNECTIONS`, logged at startup), so pool queueing cannot become the bottleneck or appear as network or Python cost. A hand-started stack uses `128`.
- **Per-request logging off** on both services (Java: `TransactionService` at `WARN`; Python: `uvicorn --no-access-log`): a synchronous stdout write would stall the WebFlux event loop or the request coroutine, adding noise unrelated to inference.

### Recorded

- **Stage timing** in every response ([API](#api)). Java: preprocessing, network, DB write, response build. Python: parsing, thread dispatch, DataFrame construction, model inference, compute stall, serialization. WebFlux's serialization of the Java response body is not captured on either side.
- **Client-side errors and contention.** Timeouts and connection errors (`status=0`) are counted apart from HTTP errors. `http_req_blocked` (client connection contention) is reported so a throughput plateau can be checked against the load generator.
- **Connection-to-worker placement**, every measured cell: which python-service worker holds each inbound connection, read from the host's procfs by `lib/placement.py` (what `ss -tnp` reports), on CPUs outside every service's cpuset, executing nothing in the measured container. At low concurrency it decides whether two in-flight requests contend for one worker's GIL.
- **Thermal state and clock** (`env_trace_log.txt`, [Suite run files](#suite-run-files)), reported per cell with pause costs and a test against latency (tables 8a to 8c). The clock is `scaling_cur_freq` sampled every 0.5 s and weighted by busy time; on cores busy only part of the time it can read below the clock the work ran at, so it is informative for loaded cells, not light ones.
- **Host provenance** (`lib/host-provenance.sh`), at the start of every run: kernel `isolcpus`, whether `irqbalance` is migrating interrupts across pinned cores, and virtualization. They can shift latency without appearing in this project's configuration, but none has one correct value for every host, so they are recorded, not enforced. The cross-host analysis gates on all three.
- **JVM GC events**, one log per rep (`gc-logs/gc_<phase>_rep<N>.log`), to cross-check tail spikes against GC pauses. The rep's pin-check probe JVMs share the container's `JAVA_TOOL_OPTIONS`, and the last of them reopens `gc.log` before warm-up, so each log spans the rep from its verification to the service JVM's exit; the GC table measures that window by the records' wall-clock timestamps. Unified JVM logging has negligible overhead and is off the request path.

---

## Experimental design rationale

- **7 repetitions per cell.** Each rep is a clean-slate restart, so the count trades wall clock against statistical power.
  - At 7 vs 7 the smallest two-sided Mann-Whitney p-value is `2/C(14,7) = 0.00058`, 0.0029 after Holm correction across the five adjacent-tier comparisons: still below α=0.05.
  - At 5 vs 5 it is 0.0079, or 0.0397 corrected: significant, with no margin for one noisy rep.
  - Below 7 reps, `pairwise_mannwhitney` prints `[!]` when even perfect separation cannot clear alpha at the realized rep count (0.333 at 2 reps per side), marking "Significant: No" as underpowered rather than null. Achieved N is printed with every result.
- **Rep-level statistics.** Requests within a rep share a JVM, a page cache and a thermal state, so they are not independent. Significance tests rank per-rep means, and CIs are cluster bootstraps over whole reps. Table 5's pooled request-level p-values are pseudoreplicated and marked *diagnostic only*.
- **Throughput measured within each repetition**, then averaged; a span pooled across reps would include the restarts and cooldowns between them. It is `(N-1)/span`, since N completion timestamps bound N-1 intervals. Calibration, table 4, figure 4 and `lib/openloop_rates.py` share this convention, so a derived iteration count and a reported throughput are the same quantity.
- **Closed-loop load for the main suite.** `per-vu-iterations` fixes the number of in-flight requests, matching a bounded caller pool and preventing unbounded queue growth in high-concurrency cells. Its known cost, coordinated omission, is checked by `run-openloop.sh` at and below the top cell's throughput; table 7 is the validity check on the closed-loop tail, not a competing result.
- **Cells calibrated to a fixed duration.** Throughput differs by a large factor between targets, so a flat `ITERATIONS_PER_VU` would give a trivial target a cell of seconds and an AI tier one of minutes. `calibrate_target()` measures each target's throughput and derives the count that makes every cell at VUS 8 and above span about 60s; VUS 1, 2 and 4 keep the flat `SCAN_ITERATIONS_PER_VU`.
  - `calibrate_scan_targets()` prepares a stack exactly like a scan rep (restart, pin checks, both warm-up passes), measures each target at `CALIB_VUS=16`, and derives `ITERATIONS_PER_VU` for each of `CALIB_AFFECTED_LEVELS` (8, 16, 32, 64) against `CALIB_TARGET_DURATION_S` (60s).
  - It writes `calib_*.json.gz`, which the analysis ignores, and `calibration_log.txt`.
- **Calibration runs once, in its own pass before the reps it serves, without running a measured cell**, so every rep of a cell runs the same workload after the same load history. Calibrating inside the first rep would give that rep an extra load period; calibrating every rep would let the workload vary. Rep-to-rep throughput drift only moves a cell's duration around 60s, and table 4e shows how much a cell mean depends on duration.
- **Turbo off, as a fixed run parameter.**
  - With turbo on, a cell's clock depends on how many cores are busy (one busy core boosts higher than many sharing the power budget), so the concurrency scan would vary clock speed along with concurrency.
  - On a laptop it also depends on heat: the host runs at full power until near its thermal limit, then the firmware cuts power, so a cell's clock depends on heat left by earlier cells. Randomized order spreads that dependence but does not remove it.
  - With turbo off, busy cores run at base clock whatever the concurrency level, the heat that would pause or throttle a run does not arise, and the setting is available on other hosts, where turbo behavior depends on each machine's cooling.
  - `REQUIRED_TURBO_OVERRIDE=on` runs the design with turbo; the setting is recorded and gated.
- **Order randomization.** Targets and concurrency levels are shuffled independently per rep, so thermal drift or a background daemon cannot systematically favour one target.
- **Fixed model hyperparameters.** `max_depth=4`, `learning_rate=0.1`, untuned. Accuracy is not an outcome; tuning would change latency without making any claim more valid.
- **Warm-up gated on convergence, not a fixed budget.** `warm-up.js` hits every target sequentially, each in its own window, and shares code with `run-target.js`, so warm-up traffic is tagged and classified like measured traffic. `converge_warmup()` re-runs it in 15s chunks (`WARMUP_CHUNK_DURATION_S`), up to four per restart (`MAX_WARMUP_CHUNKS`), until every target has settled. The criterion, `load-testing/lib/warmup_gate.py`, is shared by both harness scripts, the probes and table 0:
  - Per target, the median of the last window of HTTP 200 latencies is compared with the window before it, passing on whichever bound is looser: a change under 5%, or a gap under 0.25 ms (a percentage alone is unreachably tight for sub-millisecond targets).
  - A window is at least 500 requests and at least 3s of the target's own traffic. At the zero-work targets' throughput, 500 requests span tens of milliseconds, shorter than GC and scheduler timescales, so two such windows would read transient states as drift. Three windows still fit in one chunk at every target's throughput.
  - Every exercised target must converge; one with no HTTP 200 response never does.
  - If four chunks are not enough, the run proceeds from that state and table 0 records every target's verdict.
- **Warm-up convergence judged on the tail.** Table 0 reports drift from the first window, large by design, and between the last two windows; only the latter indicates steady state and gates `Converged`.
- **Counts, extremes and throughput corrected for subsampling** (tables 1, 4 and 7). `load_results()` pools every metric in a file into one subsampling cap, so a cell logging several metrics per request can trip the cap while each metric's own count stays under it, deflating N and throughput by about the subsampling ratio; a uniform sample also rarely keeps a cell's fastest and slowest request. A side channel keeps each cell's exact count, time span and value range, and `summarize`, `error_summary` and `_throughput_reqs_per_s` report from it. Table 6's diagnostic-only Pooled N is not corrected, since that would also require recomputing its diagnostic p-value on the full data.
- **A fully failed open-loop cell keeps its table 7 row.** Cell identity comes from all `http_req_duration` points regardless of status, so a cell where nothing succeeded, the case the check exists to surface, reports `N=0` with its `dropped_iterations` count.

---

## Threats to validity

### Construct validity: does the instrumentation measure what it claims?

- **`calibration` is a floor, not subtracted.** Instrumentation overhead stays in the AI and mock numbers.
- **`modelInferenceTimeMs` is the whole cost of obtaining a prediction**, and on this stack it is dominated by XGBoost's ingestion of the pandas DataFrame, not the booster. Micro-benchmarked against the committed models at the pinned dependency versions, tier 28: about 3.0 ms per `predict_proba` call, of which DataFrame-to-`DMatrix` conversion is about 2.9 ms (95%) and booster traversal about 0.05 ms (2%). The conversion is linear in column count, since XGBoost inspects dtypes per column per call, so this field's tier scaling is predominantly framework-level input marshalling. It is reported as measured: the service-level cost a service written this way pays, not model-evaluation cost.
- **The serialization figure is a self-referential estimate.** `totalPythonExecutionTimeMs` includes an EWMA estimate of serializing the response that carries it; table 2's `Serialization (% of total)` column bounds its effect.
- **`estimatedBridgeOverheadMs` is Docker bridge-network overhead, derived across two independent clocks.** It covers the bridge and NAT path between two containers on one host plus the serialization-estimate error, not a WAN hop, and is constant across strategies, so it cancels in differential comparisons. It can be negative and is not clamped: table 2 reports the negative rate and minimum per tier. A small, tier-consistent rate is inter-process timer noise; a large or tier-clustered rate would be a measurement fault.
- **Requests can complete below the physical floor.** Table 1e counts model-inference requests faster than the fastest `calibration` request: timing artifacts, so the affected tier's minimum is not a real latency. `mock` is not checked, since its distribution coincides with calibration's and about half its fastest requests fall below calibration's single fastest by sampling alone.
- **Single-threading is a strong, not absolute, guarantee** ([Measurement controls](#measurement-controls)).
- **The zero-compute baselines are noisier in relative terms.** `mock` and `calibration` have no compute term to dilute scheduling and queueing jitter, so their coefficient of variation and tail-to-median ratio run well above the AI tiers'. This is a property of what they measure, not harness instability, and is why the warm-up window is defined by time rather than request count. At low concurrency their rep means, and thread dispatch at VUS 1, can vary by more than the cross-host equivalence margin, so ratios built on them can come out inconclusive even between runs of one host.

### Internal validity: could something other than the manipulated variable explain the result?

- **Physical-core isolation matters most in the ablation's cpuset arm.** Widening python-service onto higher-numbered CPUs can land it on the SMT siblings of java's or k6's cores, measuring contention rather than core count. The isolation check covers every cell; re-pick those values per host.
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
- **Synthetic, uniformly random feature vectors.** The licensed dataset cannot be bundled, so `randomFeatures()` draws in a roughly PCA-shaped range. The exposure is bounded: booster traversal is structure-dominated (flat at 0.04 to 0.05 ms across all four tiers for a depth-4, 100-tree model), and the dominant DataFrame-to-`DMatrix` conversion depends on dtype and shape, not values. The models were trained on real data, so their tree structure reflects it.
- **Reduced feature space even at the largest tier.** `V1..V28` plus `Amount` is the full PCA set available, but the source dataset is itself a reduced, anonymized representation.
- **Core pinning is host-specific.** Results are not comparable across core counts or SMT settings without re-picking `cpuset` values; the SMT check aborts rather than produce incomparable numbers.
- **Results are measured with turbo off.** Absolute latency and throughput are lower than on a turbo-enabled host, and the computation-to-overhead ratio shifts with clock speed: at base clock network, framework and scheduling overhead slow more than computation, so the overhead share of end-to-end latency is higher than a turbo-enabled deployment of the same hardware would show. Within-run comparisons (tier ordering, scaling with concurrency, the ablation's mechanisms) hold every factor but the manipulated one at the same clock. `REQUIRED_TURBO_OVERRIDE=on` measures the turbo case with the same harness.
- **Absolute figures describe one host.** The cross-host analysis tests only within-run ratios; agreement across a few hosts bounds, but does not establish, how far a ratio generalizes.
- **Concurrency-scan P99s are not uniformly powered.** VUS 8 and above are duration-calibrated, so N varies by target; VUS 1, 2 and 4 use the flat `SCAN_ITERATIONS_PER_VU`. P99 CIs therefore differ in width across a row; the achieved N is printed with every result.
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
- Each pair of runs gets the percent difference of every ratio, with 90% and 95% bootstrap CIs, and a verdict against a margin fixed in advance on the ratio of their values (`--margin-pct`, default 10%). The margin is symmetric on the log scale, -9.1% to +10% at the default, so the verdict does not depend on which run is the reference:
  - `equivalent`: the 90% CI lies inside the margin (two one-sided tests at α = 0.05);
  - `different`: it lies entirely outside;
  - `inconclusive`: otherwise;
  - `insufficient reps`: fewer than two repetitions.
- Percentile bootstrap intervals over seven repetitions are approximate, so a CI bound close to the margin is weak evidence either way.

### Environment gate

Runs are compared only when they match on every field the harness or the operator controls.

- **Gated:** measured code (`measurement_fingerprint`, or the git commit for a run that predates it), run configuration (including uvicorn workers and thread-limiter tokens), JVM pins, k6 image and digest, logical CPU count, CPU quota and physical core count per service, physical-core isolation status, `isolcpus` coverage of the pinned CPUs, `irqbalance`, power source, CPU governor, turbo, WSL2 and virtualization.
- **Gated between runs of one machine only:** package power limits, which are set per model and firmware.
- **Not compared:** CPU numbers, since the same isolation maps to different numbers on different topologies. The ablation's cpuset values are compared by CPU count.
- **Reported, may differ:** hostname, machine-ID hash, CPU model, memory, kernel and Docker versions, energy preference, power profile and `thermald`.

On a mismatch the script prints both values and exits non-zero; `--allow-env-mismatch` compares anyway and names the differing fields in every caption. A field not recorded by every run is reported as unverified. Runs with entries in their failures log, or without a metadata file, are excluded. Runs sharing a hostname are labelled `<host>-<timestamp>`, and a comparison of runs from one machine is noted in every caption, since it measures between-run rather than between-host variance.

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

`load-testing/probing/` holds six standalone diagnostics, not wired into `run-suite.sh` or `run-ablation.sh`. They re-derive the harness's tuning constants on a new host, so a reproducer can justify those constants rather than inherit them.

- Each changes to its own directory first, so it runs from any working directory.
- `probe_warmup_joint.sh` and `probe_warmup_settle.sh` write their intermediates to `results/probes/` and clean up after themselves.
- `probe_ablation_taper.sh` and `calibrate_scan_iterations.sh` write into the main `results/` tree and leave their `probe_ablation_*` / `calib_*` files there.

| Script | Question it answers |
|---|---|
| `probe_warmup_joint.sh LABEL VUS [...]` | Does the real gate condition, every target converging in the same chunk, become reachable, and which target lags when it does not? Runs past `MAX_WARMUP_CHUNKS` and prints every target's verdict at every checkpoint from `lib/warmup_gate.py` itself, at the production window, minimum span, tolerance and floor unless overridden |
| `probe_warmup_settle.sh LABEL TIER VUS [...]` | Where does a single non-converging target settle? Same chunks, one target, past the cap, with a thermal check after each. `WARMUP_WINDOW_OVERRIDE` / `WARMUP_MIN_SPAN_OVERRIDE` / `WARMUP_TOL_OVERRIDE` / `WARMUP_ABS_FLOOR_OVERRIDE` change the criterion, to test how a target's verdict depends on the window and bounds at its own per-request variance |
| `calibrate_scan_iterations.sh TIER [REF_VUS] [TARGET_DURATION_S] [CALIB_ITER_PER_VU]` | What `ITERATIONS_PER_VU` does each concurrency level need on this host to hit a target cell duration? The derivation `calibrate_target()` runs, in inspectable form |
| `probe_calibration_drift.sh TIER [N_MEASUREMENTS] [REFERENCE_VUS] [ITER_PER_VU] [COOLDOWN_S]` | Does a target's calibrated throughput hold constant across reps, as the once-per-target calibration pass assumes? Repeats `calibrate_target()`'s measurement back to back and reports the spread |
| `probe_ablation_taper.sh LABEL CPUSET CPUS WORKERS TOKENS [TARGET_DURATION_S]` | Does an ablation arm's processing capacity change the cell duration it needs? Checked per arm, since each arm changes python-service's throughput by design |
| `probe_telemetry_completeness.sh [N_REQUESTS] [TARGET...]` | Is every telemetry field present on a live response, for every target? Checks build freshness against source mtimes first, then all eight `python_*` and two `java_*` fields per response |

`analysis/probing/plot_warmup_curve.py` is a seventh diagnostic, for thermal investigation rather than warm-up tuning:

- It overlays rolling P50 latency against active VUs, package temperature and core frequency within one result file (`.json` or `.json.gz`), so a throttle signature can be read against the load rather than inferred from temperature alone.
- Options: `--thermal-log` (a `sensors` poll) and/or `--turbostat-log`; `--results-dir` names a run directory.
- The active-VU line needs the `vus` metric, which finalized files omit. `calibrate_scan_iterations.sh` writes with a bare `--out json=`, bypassing the harness's filter, so its raw file still has it.

---

## Tests

The measurement instruments are unit-tested, since every reported figure depends on them. No suite runs during the Docker build, so the measured images carry no test tooling and match what is shipped.

`./install-test-deps.sh`, run once from the repo root, sets up every toolchain below: `analysis/venv` with its `requirements-dev.txt`, `services/fraud-ml-service/.venv` with its own `requirements-dev.txt`, and `bats-core`. It is separate from `setup.sh`, which prepares only the measurement stack. Maven fetches its test dependencies (JUnit, `spring-boot-starter-test`, `reactor-test`) on the first `./mvnw test`.

```bash
./install-test-deps.sh                                                     # once
(cd services/fraud-ml-service && .venv/bin/python3 -m pytest tests/ -q)    # Python service: 50 tests
(cd analysis && venv/bin/python3 -m pytest tests/ -q)                      # analysis and harness Python libraries: 195 tests
(cd services/transaction-service && ./mvnw test)                           # Java service: 34 tests
(cd load-testing && bats tests/)                                           # load-testing harness (bats-core): 148 tests
```

What they guard:

| Test | Protects |
|---|---|
| `test_responses.py` convergence tests | The EWMA serialization estimate stays sub-millisecond and cannot drift, bounding the circularity in `totalPythonExecutionTimeMs` |
| `test_model.py` timing and `n_jobs` tests | Compute stall is never negative and never exceeds wall time; computation covers its own components; `n_jobs=1` is verified on the first real prediction and an unpinned model is flagged |
| `test_api.py` telemetry symmetry | All three strategies emit identical telemetry fields, the precondition for decomposition by subtraction; `/health` reports the numeric thread environment |
| `test_api.py` baseline-floor tests | `mock` and `calibration` report zero compute, so they bound inference cost |
| `test_model.py` error-classification tests | A `ValueError` raised inside `predict_proba` (a server-side fault) reports 500, distinct from the 400 the same exception type gets as the explicit too-few-features check |
| `TransactionServiceTest` | `estimatedBridgeOverheadMs` is exactly round-trip minus Python total, negative values are preserved, and `netStart` is captured at `Mono` subscription, so a gap between building and subscribing to the call is not charged to `aiCallRoundTripTimeMs`; every telemetry field passes through; each strategy routes to its own endpoint |
| `GlobalExceptionHandlerTest` | A `ResponseStatusException` (e.g. Spring's 415 for an unsupported `Content-Type`) reports its own status rather than the generic 500 |
| `RequestTimingWebFilterTest` | The request-start stamp anchoring every Java-side figure is taken at highest filter precedence |
| `test_topology.bats` | Cpuset expansion and formatting, and the SMT-sibling and cpuset-quota guards, behave correctly on synthetic topologies the running host may not have (`TOPO_SYSFS_ROOT`), the mechanism the fault-injection suite reuses |
| `test_jvm_pins.bats` | Flag-origin parsing tells a pinned JVM value from one that coincides with it through ergonomics |
| `test_load_testing_helpers.bats` | The helpers `run-suite.sh` and `run-ablation.sh` each carry (cpuset counting and expansion, shuffling, compose lookups), tested from each script's own text, behave correctly and stay identical between the two |
| `test_warmup_convergence.bats` | The gate's window spans at least 3s of each target's own traffic, so a sub-second blip is not drift while a sustained shift is; both bounds behave as documented; one lagging target, or an expected target with no data or no HTTP 200, blocks the chunk; the verdict after the last chunk is the one reported; `run-ablation.sh`'s copy of the gate is identical to `run-suite.sh`'s |
| `test_calibration.bats` | The iteration derivation scales inversely with concurrency, clamps at one iteration per VU, fails rather than carrying a previous target's counts forward when a calibration yields nothing, and matches `analyze-results.py`'s `(N-1)/span` in both scripts; the calibration pass prepares the stack like a rep, measures each target or cell once, and every rep reads back those counts |
| `test_thermal.bats` | Temperature and throttle counters are read from the hottest zone and in core order, `na` rather than zero where the host exposes nothing; the safety check pauses, logs the pause, and aborts only when still critical after its cooldowns; neither harness script runs against a synthetic sysfs tree |
| `test_run_layout.bats` | Run directories are named per kind and host; a new run archives only the same host's earlier run of its kind; the flat-layout sweep takes only its own kind's files; `RESULTS_DIR_OVERRIDE` archives nothing; the measurement fingerprint changes with measured code but not with tests, docs or commit state |
| `test_power_state.bats` | Turbo reads correctly through all three kernel interfaces, the power source through a mains supply or a discharging battery, and both RAPL interfaces' limits; each unprepared condition is reported, a control the host lacks is not; a changed state or lost mains supply aborts the run; `prepare-host.sh` refuses without root, sets the governor, turbo and `thermald`, and fails on battery; all three harness scripts refuse a synthetic power tree |
| `test_orchestration.bats` | `run-all.sh` and `run-openloop.sh` reject bad input, and a suite run without a recorded power state, before touching the stack; the power state is checked before a run directory exists and at both edges of every measured cell; every suite cell runs under both samplers and every ablation cell under the clock sampler, stopped on both the success and the k6-failure path; the smoke test's overload cell goes through `run-openloop.sh` |
| `test_harness_libs.py` | `lib/warmup_gate.py` orders Go-trimmed timestamps numerically, sizes the window by time, reports every status and takes true medians; `lib/k6_filter.py`'s fast path keeps exactly the lines a full JSON parse would; `lib/placement.py`, on a synthetic procfs, counts connections for the uvicorn workers only (not the supervisor or its resource tracker), reports namespace PIDs, logs only changes, stops on SIGTERM and reports `placement_unavailable` rather than failing; `lib/cpufreq_sampler.py` weights each CPU's clock by its busy time, reports `na` for CPUs that never ran, and exits 3 when mains power drops, by the rule the shell applies; `lib/openloop_rates.py` derives the plateau from HTTP 200 scan completions with table 4's `(N-1)/span` |
| `test_scan_outliers.py` | Only a rep far above its design cell is flagged, and a spread under 5% is not, whatever its z-score; a cell's placement is the state it held longest with a connection open; crowding ranks every shared worker above the even split, including `2-2-0` at four connections; uneven placements are tested against even ones at the same level; table 4g and figure 9 are written only when the run recorded placement |
| `test_analysis.py` core tests | Cell-value parsing and ordering, throughput within reps, cluster bootstrap, rank-biserial effect size, GC log parsing and k6 JSON loading |
| `test_analysis.py` table 0 tests | Table 0 judges each warm-up file with the live gate at the run's recorded parameters and keeps a row for every expected target, including ones that never converged, in both analysis scripts |
| `test_analysis.py` reservoir-sampling tests | Non-200 `http_req_duration` points are kept in full regardless of file size, so the error-count cross-check is never degraded by subsampling; a truncated gzip keeps what decompressed |
| `test_analysis.py` true-count tests | Table 1/4/7's N, extremes and throughput reflect every request seen, not the reservoir's sample, including a file whose combined point count neared the cap while no single metric did; open-loop cells at different rates for one tier stay separate |
| `test_analysis.py` thermal tests | The parser reads the trace `lib/thermal.sh` and `lib/cpufreq_sampler.py` write; throttling is attributed per service as its most-throttled CPU; each cell's clock reaches table 8a and the association, and a trace without clock lines adds no clock columns; the association is taken within design cells, so the manipulated factor cannot read as heat |
| `test_analysis.py` ablation tests | Every request outcome and dropped iteration is counted before sampling, the control value comes from the run's metadata, the planned comparison takes the value farthest from control, and a failed or empty run exits non-zero |
| `test_analysis.py` significance-floor test | `pairwise_mannwhitney` emits `[!]` when the rep count keeps even perfect separation from clearing alpha |
| `test_analysis.py` open-loop cell-identity test | A cell with zero 200 responses still gets a table 7 row with its `dropped_iterations` count |
| `test_analysis.py` silent-success guard tests | `crosscheck_error_counters`, `analyze_measurement_floor` and `analyze_gc_logs` warn on empty or unmeasurable input rather than returning as if the check had passed |
| `test_host_variance.py` | Runs are found per kind and never in `archive/`; each run's outputs go to its own folder and a rejected run fails the invocation; the gate compares core counts and isolation rather than CPU numbers, gates turbo, compares power limits only within a machine, and stops on any gated difference; a uniformly slower host reads as equivalent, while a target, model-computation share or ablation effect that differs reads as different; Kendall's W reports the p-value floor of identical orderings |

---

## Fault-injection guard verification

The unit tests check each guard's logic in isolation; this checks that the guards fire through the harness's real abort path. A guard that cannot fire reports a clean run exactly as a working one does.

```bash
sudo ./prepare-host.sh
cd fault-injection
./verify-guards.sh
```

- Each of eight cases misconfigures one pinned setting the suite enforces, runs a minimal slice of `run-suite.sh` against it, and records whether the expected guard rejected it.
- Case `00-unmodified` changes nothing and must pass clean, so a suite in which every case aborts is reported as a failure, not a pass.
- Everything runs against a generated copy of the compose configuration in `fault-injection/scratch/`, whose bind mounts and results directory point inside `fault-injection/`; the top-level `results/` is untouched.
- The report goes to `fault-injection/results/guard_verification_report.{md,csv}`. Like `results/`, it is host- and run-specific regenerable evidence, so it is gitignored rather than committed.

| Case | Fault | Guard |
|---|---|---|
| `00-unmodified` | Nothing changed | none, must run clean |
| `01-smt-overlap` | python-service on the other hyperthread of each of the Java service's cores: no logical CPU shared, same physical cores | `[smt]` |
| `02-cpuset-splits-core` | python-service takes one hyperthread of each core rather than both | `[cpuset]` |
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

Clients always send the full `V1..V28` vector, whatever the tier; each endpoint slices what it needs, so one request body works against any tier.

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
- `features` must contain at least `featureTier` values. Mock and calibration ignore it.
- `transactionId` must be a UUID and `accountId` must match `ACC-\d{4,10}`, validated before the AI layer. Invalid requests get a `400` with per-field errors.

Response:

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
  "executionTimeMs": 14.7,
  "requestPreprocessingTimeMs": 0.03,
  "aiCallRoundTripTimeMs": 8.9,
  "estimatedBridgeOverheadMs": 6.59,
  "dbWriteTimeMs": 2.1,
  "responseObjectBuildTimeMs": 0.05,
  "pythonTelemetry": {
    "parsingRequestTimeMs": 0.21,
    "threadDispatchTimeMs": 0.15,
    "computationTimeMs": 1.85,
    "dataframeConstructionTimeMs": 1.23,
    "modelInferenceTimeMs": 0.62,
    "computeStallMs": 0.05,
    "serializationResponseTimeMs": 0.09,
    "totalPythonExecutionTimeMs": 2.30
  }
}
```

**Java-side fields**

| Field | Meaning |
|---|---|
| `requestPreprocessingTimeMs` | From the `RequestTimingWebFilter` stamp, taken before WebFlux dispatch, to the start of the AI call: WebFlux dispatch, request body decode, bean validation (`@Valid`) and this service's strategy/feature-tier cross-field checks. Named "preprocessing" because it is more than deserialization |
| `aiCallRoundTripTimeMs` | From just before the outbound request to `fraud-ml-service` is sent to just after its response is received. Timed inside a `Mono.defer`, so the clock starts at subscription rather than Mono assembly; the gap between building the call and WebFlux subscribing to it (handler return, the downstream `.map`, WebFlux's result-handler dispatch) counts as framework overhead, not network time |
| `estimatedBridgeOverheadMs` | `aiCallRoundTripTimeMs` minus Python's `totalPythonExecutionTimeMs`: Docker bridge-network transit, FastAPI routing, queueing, outbound-pool wait. Not a real network hop ([Threats to validity](#threats-to-validity)) |
| `dbWriteTimeMs` | `0.0` when `APP_DB_SAVE_ENABLED=false`, which benchmarks require |
| `responseObjectBuildTimeMs` | Time to assemble the final `ResponseDto` |
| `executionTimeMs` | Full Java-side duration from the `RequestTimingWebFilter` stamp, so it includes Netty and WebFlux routing |

**Python-side fields (`pythonTelemetry`)**

| Field | Meaning |
|---|---|
| `parsingRequestTimeMs` | Request parsing and validation |
| `threadDispatchTimeMs` | Thread-pool queueing before the handler runs, measured for all three strategies |
| `computationTimeMs` | The whole worker-thread window: validation, the `log1p` transform, row build, DataFrame construction, inference and threshold comparison. A superset of `dataframeConstructionTimeMs` plus `modelInferenceTimeMs`; `0.0` for mock and calibration |
| `dataframeConstructionTimeMs` | The `pd.DataFrame()` call only. XGBoost's later ingestion of that frame counts in `modelInferenceTimeMs` |
| `modelInferenceTimeMs` | The complete `predict_proba` call: feature-name validation, conversion of the DataFrame into XGBoost's `DMatrix`, and booster tree traversal ([Threats to validity](#threats-to-validity) covers what dominates it) |
| `computeStallMs` | The part of compute time the thread was off-CPU (GIL or OS scheduling) |
| `serializationResponseTimeMs` | Estimated response-serialization cost |
| `totalPythonExecutionTimeMs` | Total self-reported Python execution time |

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
| Limit / reserved | 6.0 CPU / 3G RAM (1G reserved) | 4.0 CPU / 3G RAM (1G reserved) | 4.0 CPU / 1G RAM |

- **Reproducible builds:** the service base images are pinned by digest, and python-service installs `requirements.lock` (every direct and transitive package at an exact version) rather than resolving `requirements.txt`, so a rebuild reproduces the measured images.
- **python-service:** `UVICORN_WORKERS=3` and `THREAD_LIMITER_TOKENS=40` at benchmark time. `n_jobs=1` and the BLAS variables keep each `predict_proba` call single-threaded, independent of the three workers.
- **transaction-service:**
  - The outbound pool to Python is sized by `python.service.max-connections` (default `128`, set by the harness through `PYTHON_SERVICE_MAX_CONNECTIONS`). It must stay at or above the highest VUS in `run-suite.sh`'s `CONCURRENCY_LEVELS` (`64`), or queueing inflates `estimatedBridgeOverheadMs`. `python.service.pending-acquire-timeout-ms` (default `5000`) bounds the wait.
  - The feature-tier set is fetched from Python's `/health` at startup, retrying for up to 60s.
  - The heap is fixed with `JAVA_TOOL_OPTIONS=-Xms1536m -Xmx1536m`, for the same sizing across hosts and reps.
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
│   ├── tests/                    # pytest (195): analysis pipeline, harness libraries, thermal, outliers, host variance
│   ├── requirements.txt
│   └── requirements-dev.txt      # test-only: pytest, kept off analyze-*.py's real runtime deps
├── load-testing/
│   ├── run-suite.sh              # full baseline + concurrency-scan orchestrator
│   ├── run-ablation.sh           # four-arm thread-dispatch mechanism sweep
│   ├── run-openloop.sh           # open-loop validity check against one suite run
│   ├── run-all.sh                # suite, open-loop check, ablation and both analyses in sequence
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
│   │   ├── thermal.sh            # thermal guard, per-cell temperature and throttle telemetry
│   │   ├── warmup_gate.py        # warm-up convergence criterion shared by the gate, probes and table 0
│   │   ├── placement.py          # per-cell connection-to-worker placement, read from the host's procfs
│   │   ├── openloop_rates.py     # a suite run's plateau throughput, for run-openloop.sh's rates
│   │   ├── cpufreq_sampler.py    # per-cell service-core clock and mains-power loss
│   │   └── k6_filter.py          # keeps the metrics the analysis reads and gzips each result
│   ├── probing/                  # standalone diagnostics, not wired into the suite
│   │   ├── probe_warmup_joint.sh         # all six targets, past the chunk cap, per-target tail drift
│   │   ├── probe_warmup_settle.sh        # one target, past the cap, widenable criterion
│   │   ├── calibrate_scan_iterations.sh  # per-host ITERATIONS_PER_VU derivation
│   │   ├── probe_calibration_drift.sh    # checks calibrated throughput actually holds across reps
│   │   ├── probe_ablation_taper.sh       # per-arm cell-duration check
│   │   └── probe_telemetry_completeness.sh  # per-target telemetry field presence, build-freshness check
│   └── tests/                    # bats-core (148): topology, JVM pins, shared helpers, warm-up gate, calibration, thermal, power state, run layout, orchestration
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
    │   ├── tests/                   # pytest (50): timing invariants, EWMA, telemetry symmetry
    │   ├── requirements.txt         # direct dependencies
    │   ├── requirements.lock        # full pinned environment the image installs
    │   ├── requirements-dev.txt     # test-only deps, kept out of the service image
    │   ├── models/fraud_model_v{5,10,20,28}.joblib   # pretrained, committed
    │   └── training/train_model.py  # --n-features {5,10,20,28}, omit for all four
    └── transaction-service/         # Java Spring Boot orchestrator
        └── src/
            ├── main/java/.../{config,controller,service,model,repository,dto,exception,filter}/
            └── test/java/.../       # JUnit: overhead derivation, routing, timing filter
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
- Fraud inference microservice originally by [MianBao-07](https://github.com/MianBao-07/fraud-detection-microservice).
- Containerization, mock/calibration routing, load testing, and telemetry/concurrency work by [MuhammadHussain06](https://github.com/MuhammadHussain06), integrating and extending both.
