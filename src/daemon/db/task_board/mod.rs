//! Canonical `SQLite` persistence for Task Board domain state.

mod aggregates;
mod dispatch_intents;
mod dispatch_preparations;
mod held_dispatch;
mod import_lifecycle;
mod imports;
mod items;
mod mapper;
mod policy_queues;
mod policy_runs;
mod provider_external_create_evidence;
mod provider_external_create_finalize;
mod provider_external_create_follow_up;
mod provider_external_create_rows;
mod provider_external_creates;
mod provider_sync;
mod provider_sync_conflicts;
mod rows;
mod scheduler;

#[cfg(test)]
mod item_estimate_tests;
#[cfg(test)]
mod provider_external_create_finalize_tests;
#[cfg(test)]
mod provider_external_create_follow_up_tests;
#[cfg(test)]
mod provider_external_create_optional_evidence_tests;
#[cfg(test)]
mod provider_external_create_recovery_tests;
#[cfg(test)]
mod provider_external_creates_tests;
#[cfg(test)]
mod provider_sync_backoff_tests;
#[cfg(test)]
mod provider_sync_conflict_revision_tests;
#[cfg(test)]
mod provider_sync_conflict_supersession_tests;
#[cfg(test)]
mod provider_sync_fencing_tests;
#[cfg(test)]
mod provider_sync_publication_tests;
#[cfg(test)]
mod provider_sync_renewal_tests;
#[cfg(test)]
mod provider_sync_tests;

pub(crate) use dispatch_intents::ClaimedTaskBoardDispatch;
pub(crate) use dispatch_preparations::{
    ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch,
};
#[allow(unused_imports)]
pub(crate) use imports::{TaskBoardImportMarker, TaskBoardImportResult};
#[allow(unused_imports)]
pub(crate) use items::{TaskBoardItemSnapshot, TaskBoardMutation};
pub(crate) use scheduler::{
    TaskBoardAutomationControlRecord, TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence,
    TaskBoardAutomationRunLease, TaskBoardAutomationRunStage, TaskBoardRunAcquireRequest,
};

pub(crate) const ITEMS_CHANGE_SCOPE: &str = "task_board:items";
pub(crate) const MACHINES_CHANGE_SCOPE: &str = "task_board:machines";
pub(crate) const ORCHESTRATOR_CHANGE_SCOPE: &str = "task_board:orchestrator";
pub(crate) const POLICY_RUNTIME_CHANGE_SCOPE: &str = "task_board:policy_runtime";
pub(crate) const RUNTIME_CONFIG_CHANGE_SCOPE: &str = "task_board:runtime_config";
