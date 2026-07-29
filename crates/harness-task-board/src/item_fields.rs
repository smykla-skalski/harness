//! Task-board item field types.
//!
//! Relocated to `harness_protocol::daemon::task_board::item_fields` (#1145):
//! pure data with no inherent methods, needed there because
//! `TaskBoardOrchestratorSettings`'s closure and the automation-snapshot wire
//! types embed `ExternalRef`/`ExternalRefProvider` directly. Re-exported here
//! unchanged so every existing caller keeps resolving
//! `crate::item_fields::{ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState, TaskUsage}`.
pub use harness_protocol::daemon::task_board::item_fields::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState, TaskUsage,
};
