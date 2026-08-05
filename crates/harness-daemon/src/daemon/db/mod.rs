//! Canonical daemon persistence.
//!
//! Durable domain state belongs in `DaemonDb`. Files remain outside the
//! database only when a runtime or OS integration explicitly requires them,
//! such as manifests, auth tokens, lock files, and live signal/transcript
//! artifacts.

pub(crate) use std::borrow::Cow;
pub(crate) use std::collections::BTreeMap;
pub(crate) use std::io::{Error as IoError, ErrorKind};
pub(crate) use std::path::{Path, PathBuf};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};

pub(crate) use rusqlite::{Connection, OptionalExtension, types::Type};
pub(crate) use sha2::{Digest, Sha256};

pub(crate) use crate::agents::runtime::event::ConversationEvent;
pub(crate) use crate::agents::runtime::signal::Signal;
pub(crate) use crate::daemon::agent_tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
pub(crate) use crate::daemon::index::DiscoveredProject;
pub(crate) use crate::daemon::protocol::{
    CodexRunMode, CodexRunSnapshot, CodexRunStatus, TimelineEntry,
};
pub(crate) use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionState,
    SessionStatus, TaskCheckpoint, WorkItem,
};
pub(crate) use crate::workspace::{project_context_dir, project_context_id, utc_now};
pub(crate) use harness_kernel::errors::{CliError, CliErrorKind};

pub(crate) use super::{
    index as daemon_index, protocol as daemon_protocol, state, timeline as daemon_timeline,
};
// The session snapshot layer lives in its own crate, depended on by both
// `service` and `db` (file-based signal reads, the activity-fold
// accumulator); this alias keeps every call site below unchanged.
pub(crate) use harness_daemon_snapshot as daemon_snapshot;

pub(crate) mod activity_fold;
pub(crate) use harness_daemon_db_core::activity_fold_cache;
pub(crate) use harness_daemon_db_core::audit_event_retention;
pub(crate) use harness_daemon_db_core::audit_event_retention_async;
pub use harness_daemon_db_core::{DaemonDb, SCHEMA_VERSION};
pub(crate) use harness_daemon_db_core::{
    LIVENESS_CANDIDATE_IDS_SQL, canonical_db_unavailable, db_error, i64_from_u64, u64_from_i64,
    usize_from_i64,
};
mod async_agent_turn_runs;
pub(crate) use async_agent_turn_runs::{
    AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncAgentTurnRunQueries,
};
mod async_agents;
pub(crate) use async_agents::AsyncAgentResolutionQueries;
pub(crate) use harness_daemon_db_queries::AsyncChangeTrackingQueries;
mod async_conversation;
pub(crate) use async_conversation::AsyncConversationSyncQueries;
mod async_detail;
pub(crate) use async_detail::AsyncSignalReadQueries;
pub(crate) use harness_daemon_db_queries::AsyncDiagnosticsQueries;
mod async_reads;
pub(crate) use async_reads::AsyncTimelineWindowQueries;
mod async_resolved_session;
mod async_runtime;
pub(crate) use async_runtime::AsyncRuntimeSnapshotQueries;
mod async_session_state;
pub(crate) use async_session_state::AsyncSessionStateQueries;
mod async_session_summaries;
pub(crate) use async_session_summaries::AsyncSessionSummaryQueries;
pub(crate) use harness_daemon_db_queries::AsyncSignalIndexQueries;
mod async_writes;
pub(crate) use async_writes::{AsyncDaemonTransactions, AsyncSessionWriteQueries};
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
pub(crate) use pull_request_actions::AsyncPullRequestActionQueries;
mod rebuild;
pub(crate) use rebuild::TaskReviewRebuild;
pub(crate) mod remote_acme;
pub(crate) mod remote_identity;
pub(crate) mod remote_pairing_revoke;
pub(crate) use crate::daemon::remote_pairing_queries::RemotePairingOwner;
pub(crate) use crate::daemon::remote_pairing_queries::RemotePairingRevokeOutcome;
pub(crate) mod remote_pairing;
mod review_writes;
pub(crate) use review_writes::{AsyncTaskReviewWrites, SyncTaskReviewWrites};
mod runtime;
pub use runtime::RuntimeSnapshotQueries;
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
pub use harness_daemon_db_queries::SignalIndexQueries;
mod summaries;
pub use summaries::SessionSummaryQueries;
mod summary_rows;
mod task_row;
mod task_writes;
pub(crate) mod timeline;
mod timeline_store;
mod writes;
pub use writes::SessionWriteQueries;
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
#[allow(unused_imports)]
use conversation::{
    DaemonDbConversation, clear_session_conversation_events,
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
};
pub use harness_daemon_db_core::AsyncDaemonDb;
pub(crate) use harness_daemon_db_core::SchemaRepairHooks;
#[cfg(test)]
pub(crate) use harness_daemon_db_core::set_schema_init_hook;
pub(crate) use harness_daemon_db_core::trace_async_db_operation;
#[allow(unused_imports)]
use harness_daemon_db_queries::derive_effective_signal_status;
#[allow(unused_imports)]
use harness_daemon_db_queries::import_daemon_events;
pub(crate) use harness_policy_graph_store::NewApprovalGrant;
pub(crate) use runtime::ensure_shared_db;
#[allow(unused_imports)]
use timeline::{stored_timeline_entry, stored_timeline_entry_from_row};
#[allow(unused_imports)]
use timeline_store::{
    bump_session_timeline_state, replace_all_session_timeline_entries,
    replace_session_timeline_entries_for_prefix, upsert_session_timeline_entry,
    upsert_session_timeline_entry_row,
};

pub(crate) fn normalize_change_scope(scope: &str) -> Cow<'_, str> {
    if scope == "global" || scope.starts_with("session:") || scope.starts_with("task_board:") {
        Cow::Borrowed(scope)
    } else {
        Cow::Owned(format!("session:{scope}"))
    }
}

pub(crate) fn session_status_db_label(status: SessionStatus) -> Result<String, CliError> {
    let value = serde_json::to_value(status)
        .map_err(|error| db_error(format!("serialize session status: {error}")))?;
    value
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| db_error("serialize session status: expected string"))
}

#[must_use]
#[allow(dead_code)]
pub(crate) fn parse_session_status_db_label(status: &str) -> SessionStatus {
    serde_json::from_value(serde_json::Value::String(status.to_string()))
        .unwrap_or(SessionStatus::Ended)
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[doc(hidden)]
pub struct AgentTuiLiveRefreshState {
    pub(crate) status: AgentTuiStatus,
    pub(crate) updated_at: String,
}

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
pub(crate) struct PreparedConversationEventImport {
    agent_id: String,
    runtime: String,
    events: Vec<ConversationEvent>,
}

#[derive(Debug)]
pub(crate) struct PreparedAgentTranscriptResync {
    agent_id: String,
    runtime: String,
    activity: daemon_protocol::AgentToolActivitySummary,
    events: Vec<ConversationEvent>,
}

#[derive(Debug)]
pub(crate) struct PreparedRuntimeTranscriptResync {
    session_id: String,
    agents: Vec<PreparedAgentTranscriptResync>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredTimelineEntry {
    session_id: String,
    entry_id: String,
    source_kind: String,
    source_key: String,
    recorded_at: String,
    kind: String,
    agent_id: Option<String>,
    task_id: Option<String>,
    summary: String,
    payload_json: String,
    sort_recorded_at: String,
    sort_tiebreaker: String,
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SessionTimelineStateRow {
    session_id: String,
    revision: i64,
    entry_count: usize,
    newest_recorded_at: Option<String>,
    oldest_recorded_at: Option<String>,
    integrity_hash: String,
    updated_at: String,
}

impl StoredTimelineEntry {
    fn into_timeline_entry(
        self,
        payload_scope: daemon_timeline::TimelinePayloadScope,
    ) -> Result<TimelineEntry, CliError> {
        let payload = if payload_scope == daemon_timeline::TimelinePayloadScope::Summary {
            serde_json::Value::Object(serde_json::Map::new())
        } else {
            serde_json::from_str(&self.payload_json).map_err(|error| {
                db_error(format!("parse timeline payload {}: {error}", self.entry_id))
            })?
        };
        Ok(TimelineEntry {
            entry_id: self.entry_id,
            recorded_at: self.recorded_at,
            kind: self.kind,
            session_id: self.session_id,
            agent_id: self.agent_id,
            task_id: self.task_id,
            summary: self.summary,
            payload,
        })
    }
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

/// Extract the serde tag from a serialized `SessionTransition` JSON string.
/// Returns the variant name (e.g. `SessionStarted`, `AgentJoined`) for indexing.
pub(crate) fn extract_transition_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value
                .as_object()
                .and_then(|object| object.keys().next().cloned())
                .or_else(|| value.as_str().map(String::from))
        })
        .unwrap_or_default()
}

/// Extract the discriminant from a serialized `ConversationEventKind` JSON
/// string. Returns the tagged `type` field (for example `assistant_text` or
/// `permission_asked`) for indexing.
pub(crate) fn extract_conversation_event_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value
                .as_object()
                .and_then(|object| object.get("type"))
                .and_then(serde_json::Value::as_str)
                .map(String::from)
                .or_else(|| value.as_str().map(String::from))
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
#[cfg(test)]
pub(crate) use tests::task_board::{PreparedRemoteOffer, prepare_remote_offer};
