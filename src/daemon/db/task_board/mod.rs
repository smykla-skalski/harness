//! Canonical `SQLite` persistence for Task Board domain state.

mod admission;
mod admission_lifecycle;
mod admission_recovery;
mod admission_reservations;
pub(super) use admission_lifecycle::release_managed_worker_admission_in_tx;
mod aggregates;
mod dispatch_intents;
mod dispatch_preparations;
mod dispatch_workflow_launch;
mod dispatch_workflow_start;
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
mod workflow_dispatch;
mod workflow_execution_attempts;
mod workflow_execution_candidates;
mod workflow_execution_revisions;
mod workflow_execution_rows;
mod workflow_executions;
mod workflow_recovery_selection;
mod workflow_side_effect_claims;
mod workflow_terminal;
pub(crate) use workflow_dispatch::workflow_owner;

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

pub(crate) use admission_recovery::{
    TaskBoardAdmissionMissingRunRecovery, TaskBoardAdmissionWorkerRecovery,
};
pub(crate) use dispatch_intents::{ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction};
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
