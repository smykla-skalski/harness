//! Daemon session lifecycle services.
//!
//! Signal delivery and session observation are the first two extracted
//! slices. Persistence is reached through caller-owned ports so this crate
//! never depends on the daemon crate that wires it into HTTP, WebSocket, and
//! managed-agent runtimes.

mod adopt;
mod async_ops;
mod async_send;
mod direct;
mod leave;
mod liveness;
mod mutations;
mod observe;
mod persistence;
mod ports;
mod reconcile;
mod session_setup;
mod session_teardown;
mod sessions;
mod sync;
mod timeout;
mod tui_identity;

pub use adopt::{adopt_session_record, adopt_session_record_async};
pub use async_ops::{cancel_signal_async, record_signal_ack_direct_async};
pub use async_send::send_signal_async;
pub use direct::{
    delete_session, delete_session_async, disconnect_agent, disconnect_agent_async, join_session,
    join_session_async, persist_disconnect, register_agent_runtime_session,
    register_agent_runtime_session_async, start_session, start_session_async, update_session_title,
    update_session_title_async,
};
pub use leave::{leave_session, leave_session_async};
pub use liveness::{
    SESSION_LIVENESS_REFRESH_TTL, clear_session_liveness_refresh_cache_entry,
    reconcile_active_session_liveness_background_async,
    reconcile_active_session_liveness_for_reads_async, reconcile_session_liveness_for_read_async,
    reconcile_session_liveness_for_read_returning_async, session_liveness_refresh_due_locked,
    session_liveness_refresh_due_now, stale_session_ids_for_liveness_refresh,
    stale_session_ids_for_liveness_refresh_now,
};
pub use mutations::{
    archive_session, archive_session_async, end_session, end_session_async, transfer_leader,
    transfer_leader_async,
};
pub use observe::{
    apply_heuristic_gap_tasks_async, apply_issue_tasks, apply_issue_tasks_async, observe_actor_id,
    task_severity_for_issue,
};
pub use persistence::{
    acknowledged_signal_record, build_signal_ack, pending_signal_record, record_signal_ack,
};
pub use ports::{AsyncSignalStorage, ExpiredPendingSignalIndexRecord, SignalStorage, SignalWake};
pub use reconcile::{
    liveness_project_dir_for_resolved, reconcile_expired_pending_signals,
    reconcile_expired_pending_signals_async, sync_resolved_liveness, sync_resolved_liveness_async,
};
pub use sessions::{
    list_projects, list_projects_async, list_sessions_async, resolve_runtime_session_agent_async,
    session_acp_transcript_async, session_detail_async, session_detail_core_async,
    session_detail_from_storage, session_detail_from_storage_async, session_extensions_async,
    session_timeline_window_async,
};
pub use sync::{attempt_active_signal_delivery, build_active_signal_prompt, send_signal};
pub use sync::{cancel_signal, managed_tui_id_for_registration};
