//! Canonical daemon persistence.
//!
//! Durable domain state belongs in `DaemonDb`. Files remain outside the
//! database only when a runtime or OS integration explicitly requires them,
//! such as manifests, auth tokens, lock files, and live signal/transcript
//! artifacts.

#[cfg(test)]
pub(crate) use std::collections::BTreeMap;
pub(crate) use std::sync::{Arc, Mutex, OnceLock};

pub(crate) use rusqlite::{Connection, OptionalExtension};

#[cfg(test)]
pub(crate) use crate::agents::runtime::event::ConversationEvent;
pub(crate) use crate::daemon::agent_tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
pub(crate) use crate::daemon::index::DiscoveredProject;
pub(crate) use crate::daemon::protocol::CodexRunSnapshot;
#[cfg(test)]
pub(crate) use crate::daemon::protocol::{CodexRunMode, CodexRunStatus};
#[cfg(test)]
pub(crate) use crate::session::types::AgentRegistration;
#[allow(unused_imports)]
pub(crate) use crate::session::types::SessionStatus;
#[cfg(test)]
pub(crate) use crate::session::types::WorkItem;
pub(crate) use crate::session::types::{
    SessionLogEntry, SessionSignalRecord, SessionState, TaskCheckpoint,
};
#[allow(unused_imports)]
pub(crate) use crate::workspace::project_context_id;
pub(crate) use crate::workspace::utc_now;
pub(crate) use harness_kernel::errors::{CliError, CliErrorKind};

pub(crate) use super::{
    index as daemon_index, protocol as daemon_protocol, state, timeline as daemon_timeline,
};
// The session snapshot layer lives in its own crate, depended on by both
// `service` and `db` (file-based signal reads, the activity-fold
// accumulator); this alias keeps every call site below unchanged.
pub(crate) use harness_daemon_snapshot as daemon_snapshot;

pub(crate) use harness_daemon_db_core::audit_event_retention;
pub(crate) use harness_daemon_db_core::audit_event_retention_async;
#[cfg(test)]
pub(crate) use harness_daemon_db_core::i64_from_u64;
#[allow(unused_imports)]
pub(crate) use harness_daemon_db_core::usize_from_i64;
pub use harness_daemon_db_core::{DaemonDb, SCHEMA_VERSION};
pub(crate) use harness_daemon_db_core::{canonical_db_unavailable, db_error, u64_from_i64};
#[allow(unused_imports)]
pub(crate) use harness_daemon_db_queries::DaemonDbActivityFold;
mod async_agent_turn_runs;
pub(crate) use async_agent_turn_runs::{
    AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncAgentTurnRunQueries,
};
pub(crate) use harness_daemon_db_queries::AsyncAgentResolutionQueries;
pub(crate) use harness_daemon_db_queries::AsyncChangeTrackingQueries;
pub(crate) use harness_daemon_db_queries::AsyncConversationSyncQueries;
pub(crate) use harness_daemon_db_queries::AsyncDiagnosticsQueries;
pub(crate) use harness_daemon_db_queries::AsyncSignalReadQueries;
pub(crate) use harness_daemon_db_queries::AsyncTimelineWindowQueries;
#[cfg(test)]
pub(crate) use harness_daemon_db_queries::StoredTimelineEntry;
mod async_runtime;
pub(crate) use async_runtime::AsyncRuntimeSnapshotQueries;
pub(crate) use harness_daemon_db_queries::AsyncSessionStateQueries;
pub(crate) use harness_daemon_db_queries::AsyncSessionSummaryQueries;
pub(crate) use harness_daemon_db_queries::AsyncSignalIndexQueries;
pub(crate) use harness_daemon_db_queries::sync_session_in_transaction;
pub(crate) use harness_daemon_db_queries::{AsyncDaemonTransactions, AsyncSessionWriteQueries};
mod audit;
pub(crate) use audit::AsyncAuditQueries;
pub(crate) use harness_daemon_db_queries::ChangeTrackingQueries;
#[cfg(test)]
pub(crate) use harness_daemon_db_queries::LOAD_CHANGE_TRACKING_SQL;
pub(crate) mod conversation;
pub use harness_daemon_db_queries::DaemonDbDiagnostics;
pub(crate) mod imports;
pub use imports::DaemonDbImports;
pub(crate) use imports::{
    prepare_runtime_transcript_resync, prepare_session_import_from_resolved, prepare_session_resync,
};
mod policy_graph_connection;
mod pull_request_actions;
pub(crate) use harness_daemon_db_queries::TaskReviewRebuild;
pub(crate) use pull_request_actions::AsyncPullRequestActionQueries;
pub(crate) mod remote_acme;
pub(crate) mod remote_identity;
pub(crate) mod remote_pairing_revoke;
pub(crate) use crate::daemon::remote_pairing_queries::RemotePairingOwner;
pub(crate) use crate::daemon::remote_pairing_queries::RemotePairingRevokeOutcome;
pub(crate) mod remote_pairing;
pub(crate) use harness_daemon_db_queries::{AsyncTaskReviewWrites, SyncTaskReviewWrites};
mod runtime;
pub use harness_daemon_db_queries::RuntimeSnapshotQueries;
pub(crate) use harness_daemon_db_queries::{
    codex_mode_as_str, codex_mode_from_str, codex_status_as_str, codex_status_from_str,
};
#[cfg(feature = "test-support")]
pub mod schema_query_test_support;
#[allow(dead_code)]
pub(crate) mod task_board;
pub(crate) use harness_daemon_db_core::TaskBoardSyncPermit;
#[cfg(test)]
pub(crate) use task_board::remote_assignment_terminal_handoff_tests::{
    detached_terminal_assignment, restore_parent_to_targetless_preparing,
};
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use task_board::remote_assignment_test_support::{
    CLAIMED_AT as REMOTE_EXECUTOR_CLAIMED_AT, ControllerFixture as RemoteControllerFixture,
    ExecutorFixture as RemoteExecutorFixture, PRINCIPAL as REMOTE_EXECUTOR_PRINCIPAL,
    accept_executor as accept_remote_executor, add_review_candidate as add_remote_review_candidate,
    authorize_and_start_executor as authorize_and_start_remote_executor,
    claim_request as remote_executor_claim_request,
    controller_fixture as remote_controller_fixture,
    controller_fixture_with_runtime as remote_controller_fixture_with_runtime,
    executor_fixture as remote_executor_fixture, seed_cancelable_controller_targets,
};
pub(crate) use task_board::workflow_owner;
#[cfg(test)]
pub(crate) use task_board::write_workflow_fixture::{
    approved_write_item, complete_write_preparation,
};
#[allow(unused_imports)]
pub(crate) use task_board::{
    AgentTurnStopTarget, ClaimedTaskBoardDispatch, ClaimedTaskBoardDispatchPreparation,
    ClaimedTaskBoardTriageEscalation, REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE,
    REMOTE_IMPLEMENTATION_BUNDLE_PATH, REMOTE_RESULT_ARTIFACT_MEDIA_TYPE,
    REMOTE_RESULT_ARTIFACT_PATH, REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE,
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS, REMOTE_START_PREFLIGHT_ERROR_CODE,
    REMOTE_START_PREFLIGHT_FAILURE_CLASS, ReservedTaskBoardDispatch,
    TASK_BOARD_PREPARATION_MAX_ATTEMPTS, TaskBoardAdmissionMissingRunRecovery,
    TaskBoardAdmissionWorkerRecovery, TaskBoardAutomationControlRecord,
    TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence, TaskBoardAutomationRunLease,
    TaskBoardAutomationRunStage, TaskBoardDispatchClaimAction, TaskBoardImportMarker,
    TaskBoardItemSnapshot, TaskBoardItemsSnapshot, TaskBoardLaneMutationResult,
    TaskBoardLanePositionInput, TaskBoardLaneResetInput, TaskBoardLaneShift,
    TaskBoardPreparationClaim, TaskBoardPreparationRelease, TaskBoardPreparationUnavailable,
    TaskBoardRemoteArtifact, TaskBoardRemoteArtifactStoreInput, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteControllerOperationToken, TaskBoardRemoteControllerScanItem,
    TaskBoardRemoteControllerScanStep, TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorRun,
    TaskBoardRemoteExecutorScan, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStartIoPermit, TaskBoardRemoteExecutorStartIoPermitOutcome,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopPending,
    TaskBoardRemoteExecutorStopReason, TaskBoardRemoteHostSelection, TaskBoardRemoteIoAuthority,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, TaskBoardRemoteOfferReceipt,
    TaskBoardRemoteOfferReceiptDisposition, TaskBoardRemoteOfferWindow,
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    TaskBoardRemotePriorPhaseBundle, TaskBoardRemoteRecoveryBatch, TaskBoardRemoteRecoveryFailure,
    TaskBoardRemoteResultAdoptionOutcome, TaskBoardRemoteResultImportRecord,
    TaskBoardRemoteResultImportRequest, TaskBoardRemoteResultImportState, TaskBoardRemoteRunStatus,
    TaskBoardRemoteRuntimeProvenance, TaskBoardRemoteSettlementReceipt,
    TaskBoardRemoteSourceBundle, TaskBoardRemoteSourceOfferReassignment,
    TaskBoardRemoteTerminalArtifact, TaskBoardRunAcquireRequest, TaskBoardTriageCurrentRead,
    TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideMutationResult,
    TaskBoardTriageOverrideSetInput, executor_start_authority, executor_start_io_permit,
    remote_executor_identity, remote_executor_identity_from_parts, stop_pending_snapshot_matches,
};
pub(crate) use task_board::{
    ColorEdit, DisplayNameEdit, ProjectEdit, exact_active_remote_target,
    parent_points_to_assignment,
};
// `pub`, not `pub(crate)`: `harness-db-schema`'s own v43 controller-operation
// migration test builds these trust-fence values directly to exercise the
// paired lifecycle-trust columns the v43 migration adds.
pub use task_board::{TaskBoardRemoteHostTrustFence, TaskBoardRemoteLifecycleTrustSnapshot};
#[cfg(test)]
pub(crate) use task_board::{
    accept_controller as accept_remote_controller, claim_controller as claim_remote_controller,
    running_status as remote_controller_running_status,
    status_request as remote_controller_status_request,
};
mod session_data;
pub use session_data::SessionCoreQueries;
mod signals;
pub use harness_daemon_db_queries::SessionSummaryQueries;
pub use harness_daemon_db_queries::SignalIndexQueries;
pub(crate) mod timeline;
pub use harness_daemon_db_queries::SessionWriteQueries;
pub(crate) mod prelude;

#[cfg(test)]
pub(crate) use harness_daemon_db_core::all_migration_versions;
// `pub`, not `pub(crate)`: `tests/integration_daemon.rs`'s task-board sync
// scenarios link `harness` as an ordinary dependency and need this handle
// directly, the same reason `daemon::state::test_support` is `pub` there.
pub use crate::daemon::db_open::{AsyncDaemonDbConnect, DaemonDbOpen};
pub use crate::daemon::remote_acme_queries::{
    RemoteAcmeQueries, RemoteAcmeRenewalStatus, RemoteAcmeStoredState,
};
pub use crate::daemon::remote_identity_queries::RemoteIdentitySyncQueries;
pub(crate) use crate::daemon::remote_pairing_queries::RemotePairingClaimCodeError;
pub use harness_daemon_db_core::AsyncDaemonDb;
pub(crate) use harness_daemon_db_core::SchemaRepairHooks;
#[cfg(test)]
pub(crate) use harness_daemon_db_core::set_schema_init_hook;
pub(crate) use harness_daemon_db_queries::AgentTuiLiveRefreshState;
pub(crate) use harness_daemon_db_queries::DaemonDbConversation;
#[allow(unused_imports)]
use harness_daemon_db_queries::derive_effective_signal_status;
#[allow(unused_imports)]
pub(crate) use harness_daemon_db_queries::extract_conversation_event_kind;
#[allow(unused_imports)]
pub(crate) use harness_daemon_db_queries::extract_transition_kind;
#[allow(unused_imports)]
use harness_daemon_db_queries::import_daemon_events;
#[allow(unused_imports)]
pub(crate) use harness_daemon_db_queries::parse_session_status_db_label;
#[cfg(test)]
pub(crate) use harness_daemon_db_queries::session_status_db_label;
pub(crate) use harness_daemon_db_queries::{
    PreparedAgentTranscriptResync, PreparedConversationEventImport,
};
#[allow(unused_imports)]
use harness_daemon_db_queries::{
    bump_session_timeline_state, replace_all_session_timeline_entries,
    replace_session_timeline_entries_for_prefix, upsert_session_timeline_entry,
    upsert_session_timeline_entry_row,
};
#[allow(unused_imports)]
use harness_daemon_db_queries::{
    clear_session_conversation_events, prepare_agent_conversation_imports_and_activity,
    prepare_runtime_transcript_resync_for_agents,
};
#[allow(unused_imports)]
use harness_daemon_db_queries::{stored_timeline_entry, stored_timeline_entry_from_row};
pub(crate) use harness_policy_graph_store::NewApprovalGrant;
pub(crate) use runtime::ensure_shared_db;

#[derive(Debug)]
pub(crate) struct PreparedSessionResync {
    pub(crate) resolved: daemon_index::ResolvedSession,
    log_entries: Vec<SessionLogEntry>,
    task_checkpoints: Vec<PreparedTaskCheckpointImport>,
    signals: Vec<SessionSignalRecord>,
    activities: Vec<daemon_protocol::AgentToolActivitySummary>,
    conversation_events: Vec<PreparedConversationEventImport>,
}

#[derive(Debug)]
pub(crate) struct PreparedTaskCheckpointImport {
    checkpoints: Vec<TaskCheckpoint>,
}

#[derive(Debug)]
pub(crate) struct PreparedRuntimeTranscriptResync {
    session_id: String,
    agents: Vec<PreparedAgentTranscriptResync>,
}

/// Summary of what was imported from file-based storage.
#[derive(Debug, Default)]
pub struct ImportResult {
    pub projects: usize,
    pub sessions: usize,
}

/// Summary of background file reconciliation.
#[derive(Debug, Default)]
pub struct ReconcileResult {
    pub projects: usize,
    pub sessions_imported: usize,
    pub sessions_skipped: usize,
}

#[cfg(test)]
mod tests;
#[cfg(test)]
pub(crate) use tests::task_board::{PreparedRemoteOffer, prepare_remote_offer};
