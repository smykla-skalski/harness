//! `TaskBoardOrchestratorWorkflow`.
//!
//! Relocated to
//! `harness_protocol::daemon::task_board::orchestrator_workflow` (#1145),
//! alongside `TaskBoardPhaseCapabilityProfile` (reached forward out of
//! `automation::workflow` the same way this file's own original doc comment
//! already described reaching this enum forward out of
//! `orchestrator::types`): pure data, needed there because
//! `TaskBoardOrchestratorSettings`/`TaskBoardRepositoryAutomationConfig`/
//! `TaskBoardLocalExecutionHostConfig` embed them directly. Re-exported here
//! unchanged so every existing caller keeps resolving
//! `crate::TaskBoardOrchestratorWorkflow` (this module is private;
//! `automation.rs`'s own `pub use orchestrator_workflow::*;` carries the name
//! forward the same way it always has).
pub use harness_protocol::daemon::task_board::orchestrator_workflow::TaskBoardOrchestratorWorkflow;
