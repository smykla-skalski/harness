//! Session, timeline, diagnostics, audit, and change-tracking query traits
//! for [`harness_daemon_db_core::DaemonDb`]/[`harness_daemon_db_core::AsyncDaemonDb`],
//! extracted from `harness-daemon` so `service`, `http`, and `websocket`
//! can reach the database without depending on `harness-daemon` itself.
//!
//! Every trait here is implemented directly on the db-core types, never on
//! `harness-daemon`'s own `DaemonDbOwnedHandle`/`AsyncDaemonDbHandle`
//! wrappers - those wrappers exist only to let `harness-daemon` implement
//! traits owned by *other* sibling crates (see that type's own doc comment),
//! which is a different problem than this crate solves.

mod activity_fold;
mod agent_workspace_teams;
mod agent_workspaces;
mod async_agents;
mod async_change_tracking;
mod async_conversation;
mod async_detail;
mod async_diagnostics;
mod async_reads;
mod async_resolved_session;
mod async_session_state;
mod async_session_summaries;
mod async_signal_writes;
mod async_summary_rows;
mod async_writes;
mod audit;
mod change_tracking;
mod conversation;
mod db_timeline_source;
mod diagnostics;
mod imports;
mod pull_request_actions;
mod rebuild;
mod review_writes;
mod runtime;
mod session_data;
mod signals;
mod stored_timeline_entry;
mod summaries;
mod summary_rows;
mod task_row;
mod task_writes;
mod timeline;
mod timeline_store;
mod writes;

pub use activity_fold::DaemonDbActivityFold;
pub use agent_workspace_teams::{
    AsyncAgentWorkspaceTeamOperationPreflightQueries, AsyncAgentWorkspaceTeamOperationQueries,
    AsyncAgentWorkspaceTeamQueries,
};
pub use agent_workspaces::AsyncAgentWorkspaceQueries;
pub use async_agents::AsyncAgentResolutionQueries;
pub use async_change_tracking::AsyncChangeTrackingQueries;
pub use async_conversation::AsyncConversationSyncQueries;
pub use async_detail::AsyncSignalReadQueries;
pub use async_diagnostics::AsyncDiagnosticsQueries;
pub use async_reads::AsyncTimelineWindowQueries;
pub use async_resolved_session::AsyncResolvedSessionRow;
pub use async_session_state::AsyncSessionStateQueries;
pub use async_session_summaries::AsyncSessionSummaryQueries;
pub use async_signal_writes::AsyncSignalIndexQueries;
pub use async_summary_rows::AsyncSessionSummaryRow;
pub use async_writes::{
    AsyncDaemonTransactions, AsyncSessionWriteQueries, sync_session_in_transaction,
};
pub use audit::AsyncAuditQueries;
pub use change_tracking::{ChangeTrackingQueries, LOAD_CHANGE_TRACKING_SQL};
pub use conversation::{
    DaemonDbConversation, PreparedAgentTranscriptResync, PreparedConversationEventImport,
    clear_session_conversation_events, extract_conversation_event_kind,
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
};
pub use db_timeline_source::DaemonDbTimelineHandle;
pub use diagnostics::{DaemonDbDiagnostics, import_daemon_events};
pub use imports::{
    DaemonDbImports, DaemonDbSessionResync, ImportResult, PreparedRuntimeTranscriptResync,
    PreparedSessionResync, ReconcileResult, prepare_runtime_transcript_resync,
    prepare_session_import_from_resolved, prepare_session_resync, session_state_import_required,
};
pub use pull_request_actions::AsyncPullRequestActionQueries;
pub use rebuild::TaskReviewRebuild;
pub use review_writes::{AsyncTaskReviewWrites, SyncTaskReviewWrites, TaskV10Columns};
pub use runtime::{
    AgentTuiLiveRefreshState, RuntimeSnapshotQueries, codex_mode_as_str, codex_mode_from_str,
    codex_status_as_str, codex_status_from_str,
};
pub use session_data::SessionCoreQueries;
pub use signals::{SignalIndexQueries, derive_effective_signal_status};
pub use stored_timeline_entry::StoredTimelineEntry;
pub use summaries::SessionSummaryQueries;
pub use summary_rows::{
    SessionSummaryRow, SessionSummaryScalars, SessionSummaryStateProjection,
    build_session_summary_fast, build_session_summary_from_state, parse_session_status_db_label,
    session_summary_is_legacy,
};
pub use task_row::TaskRowBindings;
pub use task_writes::replace_tasks;
pub use timeline::{
    DaemonDbTimeline, SessionTimelineStateRow, cursor_from_timeline_entry, stored_timeline_entry,
    stored_timeline_entry_for_rebuild, stored_timeline_entry_from_row,
};
pub use timeline_store::{
    bump_session_timeline_state, replace_all_session_timeline_entries,
    replace_session_timeline_entries_for_prefix, upsert_session_timeline_entry,
    upsert_session_timeline_entry_row,
};
pub use writes::{
    SessionWriteQueries, extract_transition_kind, normalize_change_scope, session_status_db_label,
};
