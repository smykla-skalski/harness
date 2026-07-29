# sccache performance and recovery evidence, 2026-07-29

## Scope and method

This run started from merged `upstream/main` at `0d8ffba91f9b765a8738e1593a96afc83a21c517` on macOS arm64 with Rust nightly 1.97.0, Cargo nightly 1.97.0, sccache 0.16.0, a 14-job Cargo budget, four nextest threads, and the format-v2 copy-on-write lane. PR #1124 later merged the measured lifecycle corrections from code head `8afdef1ed868d614e44b946c95260b4217c86a27`. Every cache statistic came from `mise run cargo:cache:status`, which resolves and queries `SCCACHE_SERVER_UDS`; the default sccache endpoint was never treated as authority.

Timing comparisons require no other lease in the shared lease directory; `ACTIVE_BUILD_COUNT=1` in `mise run cargo:env` is expected because the query itself holds one lease. The accepted samples began after the coordinator reserved a quiet window and each Cargo run was rejected if it reported `cargo-local: build contention`.

## Baseline

| Signal | Result |
| --- | --- |
| Configured socket | `/var/folders/d1/tvmyp5cs1gz38rltf390ddpw0000gn/T/harness-sccache/b72ed763e074d381.sock` |
| Configured server | reachable; PID 74871; one live server; zero known orphans |
| Cache | born 2026-07-29 10:35:14 UTC; 6.3 GiB physical size after the matrix; 30 GiB configured server budget |
| Initial counters | 6,091 requests; 2 hits; 3,330 misses; 2,742 non-cacheable calls |
| Wrapper | `.cargo/config.toml` configures `scripts/rustc-cache-wrapper.sh`; empty environment `RUSTC_WRAPPER` is expected |
| Current lane | 86.8 MiB at inventory time; APFS copy-on-write seeding enabled |
| Final counters | 8,697 requests; 5 hits; 5,022 misses; 3,640 non-cacheable calls; `historical_cache_reuse=low` |
| Contention | Coordinator-reserved quiet window; all accepted Cargo logs have no contention marker |

The focused recovery fixture started a production sccache daemon on an isolated socket and cache, deleted only that socket, identified the daemon through the retained socket ownership, and stopped it through a process-exit event. The test completed in at most 0.56 seconds across focused reruns, contains no sleeps, and did not change the configured socket, PID 74871, cache birth time, or live/orphan counts.

Three isolated copy-on-write canary samples each compiled a fresh donor, seeded four artifacts, reported the identical-source second checkout as fresh, removed the donor, and rebuilt a branch-local source change independently. This proves the reuse and independence contract on small fixtures, including donor removal and branch-local invalidation.

## Uncontended benchmark matrix

Wall times are seconds. Median and range use three steady-state samples except the explicitly single cold observations. Copy-on-write rows use the same three isolated canary runs; the total includes fixture setup and teardown, while compiler and lane-seed timings come from their logs.

| Scenario | Samples | Median | Range | Result |
| --- | --- | --- | --- | --- |
| First leaf-crate check in the session lane | 30.01 | 30.01 | single | Cold compilation dominates the first check |
| Same-lane no-op leaf check | 1.16, 1.18, 1.12 | 1.16 | 0.06 | Cargo fingerprints avoid compiler work |
| Leaf-crate edit/check | 1.66, 1.41, 1.53 | 1.53 | 0.25 | Small edit remains close to the no-op path |
| Daemon edit/check | 7.80, 6.27, 6.21 | 6.27 | 1.59 | Rootward edit recompiles a larger dependency surface |
| Fresh COW fixture plus identical checkout and branch edit | 1.86, 2.11, 1.87 | 1.87 | 0.25 | Donor compile median 0.44; seed 4 artifacts in 0.0; identical checkout 0.00; branch edit 0.03 |
| Six-group compile-only unit gate, cold | 398.71 | 398.71 | single | Compilation only; no tests executed |
| Six-group compile-only unit gate, warm | 10.45, 8.83, 8.81 | 8.83 | 1.64 | Warm same-lane compilation remains fast |
| Root Harness unit command wall time | 1.76, 1.48, 1.58 | 1.58 | 0.28 | End-to-end task overhead, preparation, and test execution |
| Root Harness test-profile preparation | 0.54, 0.49, 0.50 | 0.50 | 0.05 | Cargo-reported warm preparation before execution |
| Root Harness test bodies | 0.18, 0.12, 0.12 | 0.12 | 0.06 | Native libtest execution of 198 passing tests |

## Excluded overlapped samples

Every overlapped elapsed sample was excluded from the medians above.

| Scenario | Wall time | Exclusion |
| --- | --- | --- |
| Same-lane no-op leaf check | 2.67 | Two concurrent Cargo builds |
| Same-lane no-op leaf check | 1.43 | Two concurrent Cargo builds |
| Same-lane no-op leaf check | 1.35 | Two concurrent Cargo builds |
| Leaf-crate edit/check | 1.62 | Two concurrent Cargo builds |
| Leaf-crate edit/check | 1.57 | Two concurrent Cargo builds |
| Leaf-crate edit/check | 1.37 | Two concurrent Cargo builds |
| Full six-group nextest gate | 1,025.03 | Another worktree started `cargo build -p harness-daemon` during execution |

The excluded full nextest run still supplies diagnostic, not comparative, data: root Harness executed in 2.436 seconds, supporting crates in 128.290 seconds, `harness-agents` in 6.589 seconds, `harness-task-board` in 17.797 seconds, and `harness-daemon` in 855.498 seconds. The daemon group deterministically failed seven pre-existing workflow-state assertions, including an exact focused rerun, so the run is neither a passing gate nor accepted performance evidence. The daemon group is the clear test-runtime investigation target, but changing it is outside this cache-recovery correction.

## Decisions

- Keep Cargo incremental compilation enabled. The earlier isolated non-incremental experiment needed about 24 minutes 28 seconds for a cold six-group run and made a subsequent warm compile-only run 13.75 seconds. The uncontended default-on matrix now shows a 398.71-second cold compile-only run, an 8.83-second warm median, a 1.53-second leaf-edit median, and a 6.27-second daemon-edit median, so disabling incremental would worsen cold developer time without a proven edit-loop benefit.
- Keep checkout-specific Rust sccache keys. rustc hashes checkout paths and source arguments, `SCCACHE_BASEDIRS` does not normalize them, and changing those inputs would risk Cargo fingerprint correctness. Format-v2 copy-on-write lane seeding remains the supported cross-worktree reuse mechanism.
- Keep the 30 GiB server budget and 100 GiB destructive-cleanup guard. Independent leaked servers each enforce their own view while writing the shared directory, so the host guard remains the fail-safe; this run did not produce controlled multi-server growth evidence supporting a safer lower or higher value.
- Do not add an automatic or explicit broad warm-up task. A cold cache cannot be restored, and compiling surfaces the operator does not need would spend developer time without representative evidence of a later payoff.
- Do not change unit-test sharding or test implementations in this PR. Compile-only and actual execution are now separate, and the full diagnostic points to the daemon group, but its seven deterministic baseline failures prevent a trustworthy optimization comparison. A focused follow-up should first restore that group, then use nextest per-test timing to split stable slow tests without runner-wide serialization.

The configured server remained PID 74871 on the same socket with the same cache birth timestamp, and the final recovery dry-run reported `owners:1,orphans:0,unresolved:0`. The cache grew during normal compilation but was never deleted or reset. Deleted entries remain unrecoverable; the historical deletion actor is still unknown.
