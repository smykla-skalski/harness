// Deliberate public API facade, not scaffolding: `ExternalTask`,
// `ExternalProvider`, `ExternalSyncClient`, the `capabilities`/`config`/
// `create_recovery`/`targeting` foundation, the whole `github` client
// cluster, and now `sync`/`scopes` themselves moved into
// `harness_task_board::external`. This glob restores all of it for every
// outside caller that reaches `crate::task_board::external::*`, the same way
// root's own `task_board/mod.rs` already restores the earlier-extracted
// domain through its own `pub use harness_task_board::*;`. The
// `sync_tests`/`tests` test-only clusters stay here for the tests that don't
// reach a daemon fixture; the ones that did (`conflict_correctness_tests`,
// `provider_exclusion_status_filter_tests`, `pull_policy_tests`, `create_done`,
// `sync`/`execution_repository_tests`) relocated to `tests/integration/` as
// `task_board_external_sync_daemon*`, reading `AsyncDaemonDb` and the other
// items this move widened to `pub` for that binary's sake.
pub use harness_task_board::external::*;

#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod tests;
