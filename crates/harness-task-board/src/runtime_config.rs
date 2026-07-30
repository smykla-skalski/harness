//! Task-board git runtime and token-sync config.
//!
//! Relocated to `harness_protocol::daemon::task_board::runtime_config`
//! (#1145): pure data plus pure inherent methods (secret stripping, override
//! merging), needed there because `daemon::protocol::task_board` re-exports
//! `TaskBoardGitRuntimeConfig`/`TaskBoardGitHubTokensSyncRequest`/
//! `TaskBoardGitHubTokensSyncResponse`/`TaskBoardOpenRouterTokenSyncRequest`/
//! `TaskBoardOpenRouterTokenSyncResponse` directly. Re-exported here
//! unchanged so every existing caller keeps resolving
//! `crate::runtime_config::{...}` and `crate::task_board::normalize_repository_slug`.
pub use harness_protocol::daemon::task_board::runtime_config::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    normalize_optional_value, normalize_repository_slug,
};

#[cfg(test)]
mod tests;
