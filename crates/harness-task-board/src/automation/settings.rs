//! Durable task-board automation settings.
//!
//! Relocated to `harness_protocol::daemon::task_board::automation_settings`
//! (#1145): pure data plus trivial `Default` impls, needed there because
//! `TaskBoardOrchestratorSettings` embeds every type below directly.
//! Re-exported here unchanged so every existing caller keeps resolving
//! `crate::{TaskBoardAutomationSchedulingSettings, ...}` (this module is
//! private; `automation.rs`'s own `pub use settings::*;` carries the names
//! forward the same way it always has).
pub use harness_protocol::daemon::task_board::automation_settings::{
    TaskBoardAutomationRetrySettings, TaskBoardAutomationSchedulingSettings,
    TaskBoardExecutionHostConfig, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardRepositoryAutomationConfig,
    TaskBoardReviewerProfile, TaskBoardReviewerRule, TaskBoardReviewerSettings,
};
