//! GitHub project/automation config.
//!
//! Relocated to `harness_protocol::daemon::task_board::github_config`
//! (#1145): pure data plus pure string-matching logic, needed there because
//! `TaskBoardOrchestratorSettings` embeds `GitHubAutomationSettings` directly
//! as its `github_project` field. Re-exported here unchanged so every
//! existing caller (including `crate::github`'s own re-export of these same
//! names) keeps resolving `crate::github_config::{...}`.
pub use harness_protocol::daemon::task_board::github_config::{
    GitHubAutomation, GitHubAutomationLabels, GitHubAutomationSettings, GitHubAutomationToggles,
    GitHubMergeMethod, GitHubProjectConfig, GitHubRequestedReviewers, ProtectedPathRule,
};

#[cfg(test)]
#[path = "github_config_tests.rs"]
mod tests;
