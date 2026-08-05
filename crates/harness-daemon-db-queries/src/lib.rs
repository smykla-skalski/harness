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
mod async_agents;
mod async_change_tracking;
mod async_detail;
mod async_diagnostics;
mod async_reads;
mod async_signal_writes;
mod change_tracking;
mod conversation;
mod diagnostics;
mod review_writes;
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
pub use async_agents::AsyncAgentResolutionQueries;
pub use async_change_tracking::AsyncChangeTrackingQueries;
pub use async_detail::AsyncSignalReadQueries;
pub use async_diagnostics::AsyncDiagnosticsQueries;
pub use async_reads::AsyncTimelineWindowQueries;
pub use async_signal_writes::AsyncSignalIndexQueries;
pub use change_tracking::{ChangeTrackingQueries, LOAD_CHANGE_TRACKING_SQL};
pub use conversation::{
    DaemonDbConversation, PreparedAgentTranscriptResync, PreparedConversationEventImport,
    clear_session_conversation_events, extract_conversation_event_kind,
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
};
pub use diagnostics::{DaemonDbDiagnostics, import_daemon_events};
pub use review_writes::{AsyncTaskReviewWrites, SyncTaskReviewWrites, TaskV10Columns};
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
    SessionTimelineStateRow, cursor_from_timeline_entry, stored_timeline_entry,
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
