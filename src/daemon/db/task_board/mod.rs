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
mod items_reads;
mod lane_order;
mod lane_order_api;
mod lane_order_audit;
#[cfg(test)]
mod lane_order_tests;
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
mod remote_artifact_fetch_response;
mod remote_artifacts;
mod remote_assignment_active_fence;
mod remote_assignment_archival_fence;
#[cfg(test)]
mod remote_assignment_archival_fence_tests;
mod remote_assignment_authority_settlement;
mod remote_assignment_cancel_journal;
mod remote_assignment_cancel_response;
mod remote_assignment_cancel_status;
mod remote_assignment_claim_response;
mod remote_assignment_cleanup;
mod remote_assignment_cleanup_controller;
mod remote_assignment_controller_recovery;
mod remote_assignment_controller_scan;
#[cfg(test)]
mod remote_assignment_controller_scan_tests;
#[cfg(test)]
mod remote_assignment_controller_tests;
mod remote_assignment_executor_scan;
#[cfg(test)]
mod remote_assignment_executor_scan_tests;
mod remote_assignment_executor_stop;
#[cfg(test)]
mod remote_assignment_executor_stop_tests;
mod remote_assignment_executor_terminal;
#[cfg(test)]
mod remote_assignment_executor_terminal_contract_tests;
#[cfg(test)]
mod remote_assignment_executor_terminal_test_support;
#[cfg(test)]
mod remote_assignment_executor_terminal_tests;
mod remote_assignment_inbox;
mod remote_assignment_io_authority;
mod remote_assignment_lease;
mod remote_assignment_lease_response;
mod remote_assignment_lifecycle_owner;
#[cfg(test)]
mod remote_assignment_lifecycle_owner_tests;
mod remote_assignment_model;
mod remote_assignment_offer;
mod remote_assignment_recovery;
mod remote_assignment_recovery_queue;
#[cfg(test)]
mod remote_assignment_recovery_queue_tests;
#[cfg(test)]
mod remote_assignment_recovery_regressions;
mod remote_assignment_rejection;
mod remote_assignment_result_adoption;
mod remote_assignment_source;
mod remote_assignment_start_authority;
#[cfg(test)]
mod remote_assignment_start_authority_tests;
mod remote_assignment_status;
mod remote_assignment_status_failure;
mod remote_assignment_status_persistence;
mod remote_assignment_status_settlement;
#[cfg(test)]
mod remote_assignment_status_settlement_tests;
mod remote_assignment_stop_fence;
mod remote_assignment_terminal;
mod remote_assignment_terminal_handoff;
pub(crate) use remote_assignment_terminal_handoff::{
    exact_active_remote_target, parent_points_to_assignment,
};
mod remote_assignment_trusted_authority;
mod remote_claim_receipts;
mod remote_evidence_retention;
mod remote_hosts;
mod remote_lifecycle_trust;
mod remote_offer_receipts;
mod remote_operation_trust;
#[cfg(test)]
mod remote_operation_trust_tests;
mod remote_outbound_sources;
mod remote_result_import;
mod remote_settlement_controller;
mod remote_settlement_receipts;
mod remote_source_bundle_abandonment;
mod remote_source_bundle_controller;
mod remote_source_bundle_prior;
#[cfg(test)]
mod remote_source_bundle_prior_tests;
mod remote_source_bundle_reassignment;
mod remote_source_bundle_reassignment_evidence;
mod remote_source_bundle_recovery_controller;
mod remote_source_bundles;
mod remote_start_failure_receipts;
#[cfg(test)]
mod remote_start_receipt_hardening_tests;
mod remote_start_receipts;
mod rows;
mod scheduler;
mod workflow_dispatch;
mod workflow_dispatch_settlement;
mod workflow_execution_attempts;
mod workflow_execution_candidates;
mod workflow_execution_revisions;
mod workflow_execution_rows;
mod workflow_executions;
mod workflow_first_start_admission;
mod workflow_recovery_selection;
mod workflow_side_effect_claims;
mod workflow_start_admission;
mod workflow_target_selection;
mod workflow_terminal;
pub(crate) use workflow_dispatch::workflow_owner;

#[cfg(test)]
mod item_estimate_tests;
#[cfg(test)]
mod item_kind_tests;
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
#[cfg(test)]
mod remote_assignment_authority_tests;
#[cfg(test)]
mod remote_assignment_cancel_replay_tests;
#[cfg(test)]
mod remote_assignment_cancel_status_tests;
#[cfg(test)]
mod remote_assignment_capacity_cleanup_tests;
#[cfg(test)]
mod remote_assignment_chronology_tests;
#[cfg(test)]
mod remote_assignment_cleanup_handoff_tests;
#[cfg(test)]
mod remote_assignment_cleanup_tests;
#[cfg(test)]
mod remote_assignment_fence_tests;
#[cfg(test)]
mod remote_assignment_generation_tests;
#[cfg(test)]
pub(crate) mod remote_assignment_terminal_handoff_tests;
#[cfg(test)]
pub(crate) use remote_assignment_generation_tests::{
    accept_controller, claim_controller, running_status, status_request,
};
#[cfg(test)]
mod remote_assignment_offer_replay_tests;
#[cfg(test)]
mod remote_assignment_renewal_replay_tests;
#[cfg(test)]
pub(crate) mod remote_assignment_test_support;
#[cfg(test)]
mod remote_assignment_tests;
#[cfg(test)]
mod remote_host_sync_tests;
#[cfg(test)]
mod remote_outbound_source_recovery_tests;
#[cfg(test)]
mod remote_outbound_source_retention_tests;
#[cfg(test)]
mod remote_outbound_source_tests;
#[cfg(test)]
mod remote_settlement_test_support;
#[cfg(test)]
mod remote_settlement_tests;
#[cfg(test)]
mod remote_source_bundle_archival_tests;
#[cfg(test)]
mod remote_source_bundle_controller_tests;
#[cfg(test)]
mod remote_source_bundle_offer_recovery_tests;
#[cfg(test)]
mod remote_source_bundle_tests;
#[cfg(test)]
pub(crate) mod write_workflow_fixture;

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
pub(crate) use lane_order::{TaskBoardItemsSnapshot, TaskBoardLaneShift};
pub(crate) use lane_order_api::{
    TaskBoardLaneMutationResult, TaskBoardLanePositionInput, TaskBoardLaneResetInput,
};
#[allow(unused_imports)]
pub(crate) use remote_artifacts::{TaskBoardRemoteArtifact, TaskBoardRemoteArtifactStoreInput};
pub(crate) use remote_assignment_controller_scan::{
    TaskBoardRemoteControllerScanItem, TaskBoardRemoteControllerScanStep,
};
pub(crate) use remote_assignment_executor_scan::TaskBoardRemoteExecutorScan;
pub(crate) use remote_assignment_executor_stop::{
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopPending,
    TaskBoardRemoteExecutorStopReason, stop_pending_snapshot_matches,
};
pub(crate) use remote_assignment_executor_terminal::{
    REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
    TaskBoardRemoteTerminalArtifact,
};
#[allow(unused_imports)]
pub(crate) use remote_assignment_io_authority::{
    TaskBoardRemoteIoAuthority, TaskBoardRemoteIoAuthorityKind,
};
#[allow(unused_imports)]
pub(crate) use remote_assignment_lifecycle_owner::{
    TaskBoardRemoteExecutorLifecycleClaim, TaskBoardRemoteExecutorLifecycleOwner,
    executor_lifecycle_owner,
};
#[allow(unused_imports)]
pub(crate) use remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteControllerOperationToken,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
};
pub(crate) use remote_assignment_offer::TaskBoardRemoteOfferWindow;
#[allow(unused_imports)]
pub(crate) use remote_assignment_recovery::{
    TaskBoardRemoteRecoveryBatch, TaskBoardRemoteRecoveryFailure,
};
#[allow(unused_imports)]
pub(crate) use remote_assignment_result_adoption::TaskBoardRemoteResultAdoptionOutcome;
pub(crate) use remote_assignment_start_authority::{
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE,
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS, REMOTE_START_PREFLIGHT_ERROR_CODE,
    REMOTE_START_PREFLIGHT_FAILURE_CLASS, TaskBoardRemoteExecutorIdentity,
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteExecutorStartIoPermitOutcome, executor_start_authority,
    executor_start_io_permit, remote_executor_identity, remote_executor_identity_from_parts,
};
#[allow(unused_imports)]
pub(crate) use remote_evidence_retention::TaskBoardRemoteEvidencePruneResult;
pub(crate) use remote_hosts::{TaskBoardRemoteHostSelection, TaskBoardRemoteHostTrustFence};
pub(crate) use remote_lifecycle_trust::TaskBoardRemoteLifecycleTrustSnapshot;
pub(crate) use remote_offer_receipts::{
    TaskBoardRemoteOfferReceipt, TaskBoardRemoteOfferReceiptDisposition,
};
pub(crate) use remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
};
pub(crate) use remote_result_import::{
    TaskBoardRemoteResultImportRecord, TaskBoardRemoteResultImportRequest,
    TaskBoardRemoteResultImportState,
};
#[allow(unused_imports)]
pub(crate) use remote_settlement_receipts::TaskBoardRemoteSettlementReceipt;
#[allow(unused_imports)]
pub(crate) use remote_source_bundle_abandonment::TaskBoardRemoteSourceBundleAbandonment;
#[allow(unused_imports)]
pub(crate) use remote_source_bundle_prior::TaskBoardRemotePriorPhaseBundle;
pub(crate) use remote_source_bundle_reassignment::TaskBoardRemoteSourceOfferReassignment;
#[allow(unused_imports)]
pub(crate) use remote_source_bundles::TaskBoardRemoteSourceBundle;
#[allow(unused_imports)]
pub(crate) use remote_start_receipts::TaskBoardRemoteExecutorStartReceipt;
pub(crate) use scheduler::{
    TaskBoardAutomationControlRecord, TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence,
    TaskBoardAutomationRunLease, TaskBoardAutomationRunStage, TaskBoardRunAcquireRequest,
};

pub(crate) const ITEMS_CHANGE_SCOPE: &str = "task_board:items";
pub(crate) const MACHINES_CHANGE_SCOPE: &str = "task_board:machines";
pub(crate) const ORCHESTRATOR_CHANGE_SCOPE: &str = "task_board:orchestrator";
pub(crate) const POLICY_RUNTIME_CHANGE_SCOPE: &str = "task_board:policy_runtime";
pub(crate) const RUNTIME_CONFIG_CHANGE_SCOPE: &str = "task_board:runtime_config";
