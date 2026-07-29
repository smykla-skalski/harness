// CLI-facing network wrappers for daemon-managed session mutations and
// queries. Each function here decides whether a live daemon is reachable
// and, if so, dials it over HTTP; otherwise it falls back to the
// domain-only local mutation exported by `harness_session::service` (the
// `_local`-suffixed sibling of each function name below). This is the
// CLI-facing half of what used to be a single function fused with that
// decision inside `harness-session` itself: splitting it out here means
// `harness-session`, and through it `harness-daemon`, no longer needs to
// compile daemon-dialing code neither one runs.
//
// `harness_session::service::mod`'s own doc comments list the functions
// that keep their former fused shape instead of splitting this way. Most of
// them (`leave_session`, `session_status`, `session_agent_is_alive`,
// `build_recovery_tui_request`, `resolve_session_project_dir`,
// `register_agent_runtime_session`, `resolve_session_agent_for_runtime_session`,
// `record_signal_acknowledgment`) stay fused because a non-CLI, non-daemon
// production consumer (`harness-hooks`) depends on the dial decision and has
// no dependency path to this crate. `start_session_with_policy` and
// `join_session_with_fallback` stay fused for a different reason: the
// daemon's own no-local-database fallback (`daemon::service::direct`) reaches
// them directly with no prior local resolution, expecting them to dial
// another, database-backed daemon rather than fork state, and
// `harness-daemon`'s own facade reaches this crate directly, never through
// here. All of these names reach here unchanged through the blanket
// re-export below.

mod lifecycle;
mod queries;
mod signals;
mod tasks;

pub use harness_session::service::*;

pub use lifecycle::{
    assign_role, end_session, remove_agent, transfer_leader, update_session_title,
};
pub use queries::{list_sessions, list_sessions_global};
pub use signals::{cancel_signal, list_signals, send_signal};
pub use tasks::{
    assign_task, create_task_with_source, delete_task, drop_task, record_task_checkpoint,
    update_task,
};
