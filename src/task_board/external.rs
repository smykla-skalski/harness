// Deliberate public API facade, not scaffolding: `ExternalTask`,
// `ExternalProvider`, `ExternalSyncClient`, the `capabilities`/`config`/
// `create_recovery`/`targeting` foundation, the whole `github` client
// cluster, and now `sync`/`scopes` themselves moved into
// `harness_task_board::external`. This glob restores all of it for every
// outside caller that reaches `crate::task_board::external::*`, the same way
// root's own `task_board/mod.rs` already restores the earlier-extracted
// domain through its own `pub use harness_task_board::*;`. Only the
// `sync_tests`/`tests` test-only clusters stay here: several of their files
// reach `crate::daemon::db::AsyncDaemonDb`/`crate::daemon::client::test_support`
// as integration-test fixtures and need to relocate to `tests/integration/`
// first.
pub use harness_task_board::external::*;

#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod tests;
