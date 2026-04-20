use std::collections::BTreeMap;
use std::env;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::id as process_id;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crate::agents::runtime as agents_runtime;
use crate::agents::runtime::signal::{
    AckResult, SignalAck, acknowledge_signal as write_signal_ack,
};
use crate::agents::service as agents_service;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::session::types::{
    AgentRegistration, SessionLogEntry, SessionState, SessionStatus, SessionTransition, TaskSource,
};
use crate::session::{
    observe as session_observe, service as session_service, storage as session_storage,
};
use crate::workspace::utc_now;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio::runtime::Handle;
use tokio::sync::{broadcast, watch as tokio_watch};
use tokio::task::AbortHandle;

use super::agent_tui::AgentTuiManagerHandle;
use super::bridge;
use super::codex_controller::CodexControllerHandle;
use super::codex_transport::{self, CodexTransportKind};
use super::http::{self, DaemonHttpState};
use super::index::{self, ResolvedSession};
use super::launchd::{self, LaunchAgentStatus};
#[cfg(test)]
use super::protocol::TimelineCursor;
use super::protocol::{
    AgentRemoveRequest, DaemonControlResponse, DaemonDiagnosticsReport, HealthResponse,
    LeaderTransferRequest, LogLevelResponse, ObserveSessionRequest, ProjectSummary,
    ReadyEventPayload, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionExtensionsPayload, SessionLeaveRequest, SessionSummary, SessionUpdatedPayload,
    SessionsUpdatedPayload, SetLogLevelRequest, SignalAckRequest, SignalCancelRequest,
    SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest,
    TaskDropRequest, TaskQueuePolicyRequest, TaskUpdateRequest, TimelineEntry,
    TimelineWindowRequest, TimelineWindowResponse,
};
use super::snapshot;
use super::state::{self, DaemonDiagnostics, DaemonManifest};
use super::timeline;
use super::watch;
use super::websocket::ReplayBuffer;

#[derive(Debug, Clone)]
struct DaemonObserveRuntime {
    sender: broadcast::Sender<StreamEvent>,
    poll_interval: Duration,
    running_sessions: Arc<Mutex<BTreeMap<String, ObserveLoopRegistration>>>,
    db: Arc<OnceLock<Arc<Mutex<super::db::DaemonDb>>>>,
    async_db: Arc<OnceLock<Arc<super::db::AsyncDaemonDb>>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ObserveLoopRequest {
    actor_id: Option<String>,
}

impl ObserveLoopRequest {
    fn new(actor_id: Option<&str>) -> Self {
        Self {
            actor_id: actor_id
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string),
        }
    }
}

#[derive(Debug)]
struct ObserveLoopRegistration {
    request: ObserveLoopRequest,
    generation: u64,
    abort_handle: AbortHandle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ObserveLoopState {
    Unavailable,
    Started,
    AlreadyRunning,
    Restarted,
}

static OBSERVE_RUNTIME: OnceLock<DaemonObserveRuntime> = OnceLock::new();
static SHUTDOWN_SIGNAL: OnceLock<tokio_watch::Sender<bool>> = OnceLock::new();
static SESSION_LIVENESS_REFRESH_CACHE: OnceLock<Mutex<BTreeMap<String, Instant>>> = OnceLock::new();

const SESSION_LIVENESS_REFRESH_TTL: Duration = Duration::from_secs(5);
const ACTIVE_SIGNAL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const ACTIVE_SIGNAL_ACK_POLL_INTERVAL: Duration = Duration::from_millis(50);

struct ActiveSignalDelivery<'a> {
    session_id: &'a str,
    agent_id: &'a str,
    signal: &'a agents_runtime::signal::Signal,
    runtime: &'a dyn agents_runtime::AgentRuntime,
    project_dir: &'a Path,
    signal_session_id: &'a str,
    db: Option<&'a super::db::DaemonDb>,
}

struct ManagedTuiWake<'a> {
    tui_id: &'a str,
    manager: &'a AgentTuiManagerHandle,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatusReport {
    pub manifest: Option<DaemonManifest>,
    pub launch_agent: LaunchAgentStatus,
    pub project_count: usize,
    pub worktree_count: usize,
    pub session_count: usize,
    pub diagnostics: DaemonDiagnostics,
}

#[derive(Debug, Clone)]
pub struct DaemonServeConfig {
    pub host: String,
    pub port: u16,
    pub poll_interval: Duration,
    pub observe_interval: Duration,
    /// Whether the daemon is running inside the macOS App Sandbox.
    ///
    /// When true, subprocess-based platform integration (e.g. `launchctl`
    /// invocations, respawning the daemon binary directly) is disabled and
    /// surfaces a structured error instead of attempting the operation.
    pub sandboxed: bool,
    /// How the daemon should reach its Codex app-server. Sandboxed daemons
    /// default to WebSocket because they cannot spawn subprocesses; the
    /// unsandboxed default is stdio. See [`codex_transport_from_env`].
    pub codex_transport: CodexTransportKind,
}

impl Default for DaemonServeConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 0,
            poll_interval: Duration::from_secs(2),
            observe_interval: Duration::from_secs(5),
            sandboxed: false,
            codex_transport: CodexTransportKind::Stdio,
        }
    }
}

/// Resolve the Codex transport kind for a given sandbox mode, consulting
/// `HARNESS_CODEX_WS_URL`. Delegates to [`codex_transport::codex_transport_from_env`].
#[must_use]
pub fn codex_transport_from_env(sandboxed: bool) -> CodexTransportKind {
    codex_transport::codex_transport_from_env(sandboxed)
}

/// Returns true when `HARNESS_SANDBOXED` is set to a truthy value (`1`, `true`, `yes`, `on`).
#[must_use]
pub fn sandboxed_from_env() -> bool {
    env::var("HARNESS_SANDBOXED").ok().is_some_and(|value| {
        matches!(
            value.trim(),
            "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
        )
    })
}

/// Returns true when the current working directory is under
/// `Library/Group Containers/`, which is a strong signal that the process
/// launched inside the macOS App Sandbox.
#[must_use]
pub fn cwd_looks_sandboxed() -> bool {
    env::current_dir()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .is_some_and(|path| path.contains("Library/Group Containers/"))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_sandbox_startup(sandboxed: bool) {
    tracing::info!(sandboxed, "daemon starting");
    if !sandboxed && cwd_looks_sandboxed() {
        tracing::warn!(
            "daemon cwd is under Library/Group Containers/ but HARNESS_SANDBOXED is unset; \
             subprocess features may fail under the macOS App Sandbox"
        );
    }
}

use crate::daemon::agent_tui;
use crate::daemon::db;
use crate::daemon::protocol;
use crate::daemon::voice;
use crate::daemon::{is_local_websocket_endpoint, is_loopback_host};

mod direct;
mod leave;
mod mutations;
mod mutations_async;
mod observe_async;
mod observe_loop;
mod observe_persistence;
mod observe_stream;
mod read_reconciliation;
mod serve;
mod session_setup;
mod sessions;
mod signals;
mod signals_async;
mod signals_async_send;
mod status;
mod sync_support;

pub use direct::{
    disconnect_agent_direct, join_session_direct, record_signal_ack_direct,
    register_agent_runtime_session_direct, start_session_direct, update_session_title_direct,
};
pub(crate) use direct::{
    disconnect_agent_direct_async, join_session_direct_async,
    register_agent_runtime_session_direct_async, start_session_direct_async,
    update_session_title_direct_async,
};
pub use leave::leave_session;
pub(crate) use leave::leave_session_async;
pub use mutations::{
    assign_task, change_role, checkpoint_task, create_task, drop_task, end_session, remove_agent,
    transfer_leader, update_task, update_task_queue_policy,
};
pub(crate) use mutations_async::{
    assign_task_async, change_role_async, checkpoint_task_async, create_task_async,
    drop_task_async, end_session_async, remove_agent_async, transfer_leader_async,
    update_task_async, update_task_queue_policy_async,
};
pub use observe_stream::{
    broadcast_session_extensions, broadcast_session_snapshot, broadcast_session_updated,
    broadcast_session_updated_core, broadcast_sessions_updated, global_stream_initial_events,
    observe_session, ready_event, session_extensions_event, session_stream_initial_events,
    session_updated_core_event, session_updated_event, sessions_updated_event,
};
pub use serve::serve;
pub use sessions::{
    list_projects, list_sessions, session_detail, session_detail_core, session_extensions,
    session_timeline,
};
pub use signals::{cancel_signal, send_signal};
pub use status::{
    diagnostics_report, get_log_level, health_response, request_shutdown, set_log_level,
    status_report,
};

pub(crate) use observe_async::{observe_session_async, run_daemon_observe_task_async};
pub(crate) use observe_loop::*;
pub(crate) use observe_persistence::{
    apply_heuristic_gap_tasks_to_async_db, apply_issue_tasks_to_async_db, apply_issue_tasks_to_db,
    observe_actor_id,
};
pub(crate) use observe_stream::{
    broadcast_session_extensions_async, broadcast_session_snapshot_async,
    broadcast_session_updated_core_async, broadcast_sessions_updated_async,
    global_stream_initial_events_async, session_stream_initial_events_async,
    session_updated_core_event_async, sessions_updated_event_async,
};
pub(crate) use read_reconciliation::*;
#[cfg(test)]
pub(crate) use sessions::session_timeline_window;
pub(crate) use sessions::{
    list_projects_async, list_sessions_async, resolve_runtime_session_agent_async,
    session_detail_async, session_detail_core_async, session_detail_from_async_daemon_db,
    session_detail_from_daemon_db, session_extensions_async, session_timeline_window_async,
};
pub(crate) use signals_async::{cancel_signal_async, record_signal_ack_direct_async};
pub(crate) use signals_async_send::send_signal_async;
pub(crate) use status::{diagnostics_report_async, health_response_async};
pub(crate) use sync_support::{
    acknowledged_signal_record, append_leave_signal_logs_to_db, append_task_drop_effect_logs,
    append_transfer_logs_to_async_db, append_transfer_logs_to_db, build_log_entry,
    build_signal_ack, effective_project_dir, pending_signal_record, project_dir_for_db_session,
    reconcile_expired_pending_signals_for_db, record_signal_ack, refresh_signal_index_for_db,
    resolve_hook_agent, session_not_found, task_drop_effect_signal_records,
    write_task_start_signals,
};

#[cfg(test)]
pub(crate) use serve::session_import_required;
#[cfg(test)]
pub(crate) use sessions::{
    build_timeline_window_response, clear_session_liveness_refresh_cache_entry,
    stale_session_ids_for_liveness_refresh,
};
#[cfg(test)]
pub(crate) use status::current_log_level;

#[cfg(test)]
mod tests;
