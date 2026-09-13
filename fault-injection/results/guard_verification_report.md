# Guard verification

Generated 2026-09-13T13:04:06Z on Linux 7.0.0-31-generic.

Baseline cpusets from docker-compose.yml defaults: python `0-1,4-5,8-9`.

Each case misconfigures one pinned setting and runs a minimal slice of the suite
against it. PASS means the named guard rejected the run; for the unmodified case it
means the run completed with no guard firing.

| Case | Fault | Stage | Guard | Outcome | Verdict |
|---|---|---|---|---|---|
| 00-unmodified | unmodified configuration | stack | `none` | ran clean | PASS |
| 01-smt-overlap | python-service pinned onto the Java service's physical cores | pre-container | `[smt]` | rejected by [smt] | PASS |
| 02-cpuset-splits-core | python-service takes one hyperthread of each core, not both | pre-container | `[cpuset]` | rejected by [cpuset] | PASS |
| 03-cpuset-nonexistent-cpu | cpuset names a CPU that does not exist on this host | pre-container | `[smt]` | rejected by [smt] | PASS |
| 04-cpu-quota-exceeds-cpuset | CPU quota larger than the cpuset can supply | pre-container | `[cpuset]` | rejected by [cpuset] | PASS |
| 05-thread-limiter-drift | thread limiter tokens away from the pinned baseline | stack | `[tier-check]` | rejected by [tier-check] | PASS |
| 06-feature-tier-drift | python-service loads an incomplete set of feature tiers | stack | `[tier-check]` | rejected by [tier-check] | PASS |
| 07-gc-threads-unpinned | GC worker thread count left to JVM ergonomics | stack | `[jvm-pin]` | rejected by [jvm-pin] | PASS |
| 08-collector-swapped | collector swapped from G1 to Parallel | stack | `[jvm-pin]` | rejected by [jvm-pin] | PASS |

9 passed, 0 failed, 0 skipped.

Not covered: a configuration whose pinned options are present but never reach the
JVM. The guard checks that case through the flag origin the JVM reports, which no
compose-level fault can reproduce.
