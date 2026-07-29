# sccache performance and recovery evidence, 2026-07-29

## Scope and method

This run started from merged `upstream/main` at `0d8ffba91f9b765a8738e1593a96afc83a21c517` on macOS arm64 with Rust nightly 1.97.0, Cargo nightly 1.97.0, sccache 0.16.0, a 14-job Cargo budget, four nextest threads, and the format-v2 copy-on-write lane. Every cache statistic came from `mise run cargo:cache:status`, which resolves and queries `SCCACHE_SERVER_UDS`; the default sccache endpoint was never treated as authority.

The preserved raw output is under the ignored `.cache/diagnostics/sccache-performance-20260729/` directory in the session worktree. Timing comparisons require `ACTIVE_BUILD_COUNT=1` in `mise run cargo:env`, because the query itself holds one lease. For more than five minutes the host continuously reported two to four leases, including workspace-wide clippy builds at PIDs 28306, 25841, and 56021, `harness-daemon` clippy at PID 55432, and focused daemon test compilations at PIDs 23937 and 45959. No elapsed-time sample from that window is a valid cold, warm, edit-loop, cross-worktree, or test-execution comparison, so the representative benchmark matrix remains an explicit unresolved gate.

## Baseline

| Signal | Result |
| --- | --- |
| Configured socket | `/var/folders/d1/tvmyp5cs1gz38rltf390ddpw0000gn/T/harness-sccache/b72ed763e074d381.sock` |
| Configured server | reachable; PID 74871; one live server; zero known orphans |
| Cache | born 2026-07-29 10:35:14 UTC; 5.6 GiB physical size; 30 GiB configured server budget |
| Initial counters | 6,091 requests; 2 hits; 3,330 misses; 2,742 non-cacheable calls |
| Wrapper | `.cargo/config.toml` configures `scripts/rustc-cache-wrapper.sh`; empty environment `RUSTC_WRAPPER` is expected |
| Current lane | 86.8 MiB at inventory time; APFS copy-on-write seeding enabled |
| Contention | `ACTIVE_BUILD_COUNT=4`; timing benchmark deferred |

The focused recovery fixture started a production sccache daemon on an isolated socket and cache, deleted only that socket, identified the daemon through the retained socket ownership, and stopped it through a process-exit event. The test completed in at most 0.56 seconds across focused reruns, contains no sleeps, and did not change the configured socket, PID 74871, cache birth time, or live/orphan counts.

Three isolated copy-on-write canary samples each compiled a fresh donor, seeded four artifacts, reported the identical-source second checkout as fresh, removed the donor, and rebuilt a branch-local source change independently. This proves the reuse and independence contract on small fixtures, including donor removal and branch-local invalidation. Their elapsed values remain in the raw logs but are intentionally excluded from performance conclusions because other Cargo builds overlapped them.

## Decisions

- Keep Cargo incremental compilation enabled. The earlier isolated non-incremental experiment needed about 24 minutes 28 seconds for a cold six-group run and made a subsequent warm compile-only run 13.75 seconds, but the cold penalty and lack of uncontended edit-loop samples do not establish a net developer-time win.
- Keep checkout-specific Rust sccache keys. rustc hashes checkout paths and source arguments, `SCCACHE_BASEDIRS` does not normalize them, and changing those inputs would risk Cargo fingerprint correctness. Format-v2 copy-on-write lane seeding remains the supported cross-worktree reuse mechanism.
- Keep the 30 GiB server budget and 100 GiB destructive-cleanup guard. Independent leaked servers each enforce their own view while writing the shared directory, so the host guard remains the fail-safe; this run did not produce controlled multi-server growth evidence supporting a safer lower or higher value.
- Do not add an automatic or explicit broad warm-up task. A cold cache cannot be restored, and compiling surfaces the operator does not need would spend developer time without representative evidence of a later payoff.
- Do not change unit-test sharding or test implementations in this PR. The observed long-running process was still compiling `harness-daemon`, not executing a test body, and there was no uncontended nextest timing artifact from which to identify a stable runtime bottleneck. Use the existing compile, unit, and integration profile tasks to keep those phases separate when the host is idle.

## Follow-up benchmark matrix

When the host is uncontended, collect at least three samples for each row and report the median plus range: a genuinely fresh lane, a same-lane no-op rerun, a leaf-crate edit/check, a root or daemon edit/check, an identical-source worktree seeded from an idle donor, the same second worktree after a branch-local edit, compile-only unit gates, and actual nextest execution. Run the same matrix with `CARGO_INCREMENTAL=0` only in isolated benchmark lanes; do not compare it with incremental-on samples taken under different contention. Keep lane clone time, compiler time, and nextest execution time in separate columns.
