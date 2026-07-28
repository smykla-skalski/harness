// Deliberate public API facade, not scaffolding: `GitHubApiAutomationClient`,
// `GitHubAutomationClient`, the `client`/`client_graphql`/`evidence`/
// `evidence_api`/`publication`/`repository`/`risk` cluster, and
// `build_auto_merge_policy_input` moved into `harness_task_board::github`.
// This glob restores all of it for every outside caller that reaches
// `crate::task_board::github::*`, the same way root's own `task_board/mod.rs`
// already restores the earlier-extracted domain through its own
// `pub use harness_task_board::*;`. Distinct from
// `crate::task_board::external::github`, the sync-engine-specific GitHub
// client already living in `harness_task_board::external`.
pub use harness_task_board::github::*;
