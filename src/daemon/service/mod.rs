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

use super::agent_acp::AcpAgentManagerHandle;
use super::agent_tui::AgentTuiManagerHandle;
use super::bridge;
use super::codex_controller::CodexControllerHandle;
use super::codex_transport::{self, CodexTransportKind};
use super::http::{self, DaemonHttpAuthMode, DaemonHttpState, RemoteRequestLimitConfig};
use super::index::{self, ResolvedSession};
use super::launchd::{self, LaunchAgentStatus};
#[cfg(test)]
use super::protocol::TimelineCursor;
use super::protocol::{
    AgentRemoveRequest, DAEMON_WIRE_VERSION, DaemonControlResponse, DaemonDiagnosticsReport,
    HealthResponse, LeaderTransferRequest, LogLevelResponse, ObserveSessionRequest, ProjectSummary,
    ReadyEventPayload, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionExtensionsPayload, SessionLeaveRequest, SessionSummary, SessionUpdatedPayload,
    SessionsUpdatedDeltaPayload, SessionsUpdatedPayload, SetLogLevelRequest, SignalAckRequest,
    SignalCancelRequest, SignalSendRequest, StreamEvent, TaskAssignRequest, TaskCheckpointRequest,
    TaskCreateRequest, TaskDeleteRequest, TaskDropRequest, TaskQueuePolicyRequest,
    TaskUpdateRequest, TimelineEntry, TimelineWindowRequest, TimelineWindowResponse,
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

#[must_use]
pub(crate) fn observe_async_db() -> Option<Arc<super::db::AsyncDaemonDb>> {
    OBSERVE_RUNTIME.get()?.async_db.get().cloned()
}

pub(crate) fn observe_sender() -> Option<broadcast::Sender<StreamEvent>> {
    Some(OBSERVE_RUNTIME.get()?.sender.clone())
}

pub(crate) const SESSION_LIVENESS_REFRESH_TTL: Duration = Duration::from_secs(5);
const ACTIVE_SIGNAL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const ACTIVE_SIGNAL_ACK_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Per-signal coordinates for active wake delivery.
///
/// Deliberately holds no DB handle — that field used to live here but
/// `&DaemonDb` carries `RefCell<rusqlite::Connection>` which is `!Sync`,
/// so binding the struct once across an await pulled a non-Send future
/// into `tokio::spawn`. Callers that need to record acks pass
/// `Option<&DaemonDb>` as a separate argument.
#[derive(Clone, Copy)]
struct SignalCoords<'a> {
    session_id: &'a str,
    agent_id: &'a str,
    signal: &'a agents_runtime::signal::Signal,
    runtime: &'a dyn agents_runtime::AgentRuntime,
    project_dir: &'a Path,
    signal_session_id: &'a str,
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
    pub auth_mode: DaemonHttpAuthMode,
    pub remote_domain: Option<String>,
    pub remote_request_limits: Option<RemoteRequestLimitConfig>,
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
            auth_mode: DaemonHttpAuthMode::Local,
            remote_domain: None,
            remote_request_limits: None,
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
    super::sandboxed_from_env()
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

use crate::daemon::db;
use crate::daemon::protocol;
use crate::daemon::{is_local_websocket_endpoint, is_loopback_host};

mod adopt;
mod direct;
mod improver_apply;
mod leave;
mod mutations;
mod mutations_async;
mod observe_async;
mod observe_loop;
mod observe_persistence;
mod observe_stream;
mod openrouter_models;
mod read_reconciliation;
mod resolved_events;
mod review_mutations;
mod review_mutations_async;
mod review_submit_txn;
mod reviews;
mod reviews_files;
mod reviews_github_policy;
mod reviews_thread_resolve;
mod reviews_timeline;
mod serve;
#[cfg(test)]
pub(crate) use serve::test_support::{
    install_deterministic_runtime_seam, reconcile_task_board_remote_executor_tick,
};
mod session_setup;
mod session_teardown;
mod sessions;
mod signals;
mod signals_async;
mod signals_async_send;
mod signals_timeout;
mod status;
mod sync_support;
mod task_board;
pub(crate) use task_board::{validate_read_only_workflow_launch, validate_write_workflow_launch};
mod task_board_automation_force_cancel;
#[cfg(test)]
mod task_board_automation_force_cancel_tests;
#[cfg(test)]
mod task_board_automation_force_cancel_regression_tests;
mod task_board_automation_runtime;
mod task_board_remote_result_import;
pub(crate) use task_board_remote_result_import::import_and_adopt_task_board_remote_implementation_result;
#[cfg(test)]
pub(crate) use task_board_remote_result_import::{
    cleanup_task_board_remote_result_import, import_task_board_remote_implementation_result,
};
mod task_board_completion;
mod task_board_db;
mod task_board_evaluation;
mod task_board_github;
#[cfg(test)]
mod task_board_host;
#[cfg(test)]
mod task_board_orchestrator;
mod task_board_orchestrator_control;
mod task_board_orchestrator_db;
mod task_board_orchestrator_run_lease;
mod task_board_orchestrator_settings;
mod task_board_orchestrator_step_mode;
pub(crate) mod task_board_read_only_coordinator;
#[cfg(test)]
mod task_board_read_only_coordinator_tests;
mod task_board_read_only_runtime;
pub(crate) mod task_board_remote_controller;
mod task_board_runtime;
#[cfg(test)]
mod task_board_sync_tests;
mod task_board_workflow_execution;
#[cfg(test)]
mod task_board_workflow_execution_tests;
#[cfg(test)]
mod task_board_workflow_repository_tests;
mod task_board_workflow_review;
#[cfg(test)]
mod task_board_workflow_review_tests;
#[cfg(test)]
mod task_board_workflow_test_support;
mod wake_route;

pub use crate::reviews::fetch_review_avatar;
pub use adopt::adopt_session_record;
pub(crate) use adopt::adopt_session_record_async;
pub use direct::{
    delete_session_direct, disconnect_agent_direct, join_session_direct, record_signal_ack_direct,
    register_agent_runtime_session_direct, start_session_direct, update_session_title_direct,
};
pub(crate) use direct::{
    delete_session_direct_async, disconnect_agent_direct_async, ensure_project_registered_async,
    join_session_direct_async, register_agent_runtime_session_direct_async,
    start_session_direct_async, update_session_title_direct_async,
};
pub use improver_apply::improver_apply;
pub(crate) use improver_apply::improver_apply_async;
pub use leave::leave_session;
pub(crate) use leave::leave_session_async;
pub use mutations::{
    archive_session, assign_task, change_role, checkpoint_task, create_task, delete_task,
    drop_task, end_session, remove_agent, transfer_leader, update_task, update_task_queue_policy,
};
pub(crate) use mutations_async::{
    archive_session_async, assign_task_async, change_role_async, checkpoint_task_async,
    create_task_async, create_task_with_id_async, delete_task_async, drop_task_async,
    end_session_async, remove_agent_async, transfer_leader_async, update_task_async,
    update_task_queue_policy_async,
};
pub use observe_stream::{
    broadcast_session_extensions, broadcast_session_snapshot, broadcast_session_updated,
    broadcast_session_updated_core, broadcast_sessions_updated, global_stream_initial_events,
    observe_session, ready_event, session_extensions_event, session_stream_initial_events,
    session_updated_core_event, session_updated_event, sessions_updated_event,
};
pub use openrouter_models::list_openrouter_models;
pub use review_mutations::{
    arbitrate as arbitrate_review, claim_review, respond_review, submit_for_review, submit_review,
};
pub(crate) use review_mutations_async::{
    arbitrate_async as arbitrate_review_async, claim_review_async, respond_review_async,
    submit_for_review_async, submit_review_async,
};
pub use reviews::{
    add_label_to_reviews, add_review_file_comment, approve_reviews, auto_reviews,
    catalog_review_repositories, clear_reviews_cache, comment_on_reviews, fetch_review_body,
    merge_reviews, preview_review_action, preview_reviews_policy, query_reviews, refresh_reviews,
    request_review_for_reviews, rerun_reviews_checks, resolve_review_pull_requests,
    reviews_capabilities, reviews_policy_history, reviews_policy_status, start_reviews_policy_run,
    update_review_body,
};
pub(crate) use reviews::{
    preview_review_action_with_audit_db, preview_reviews_policy_with_audit_db,
    reviews_policy_history_with_audit_db, reviews_policy_status_with_audit_db,
    start_reviews_policy_run_with_audit_db,
};
pub use reviews_files::{
    GcReport, delete_review_local_clone, fetch_review_file_blob, list_review_files,
    list_review_local_clones, mark_review_files_viewed, patch_review_files, preview_review_files,
    register_local_clone_progress_sender, run_local_clone_gc,
};
pub use reviews_thread_resolve::set_review_thread_resolved;
pub use reviews_timeline::{clear_reviews_caches_with_timeline, fetch_review_timeline};
pub use serve::serve;
pub(crate) use serve::{
    ShutdownSignalGuard, recover_remote_assignments_before_local_work, serve_remote_https,
};
pub use sessions::{
    list_projects, list_sessions, session_detail, session_detail_core, session_extensions,
    session_timeline,
};
pub(crate) use signals::record_signal_ack_and_broadcast;
pub(crate) use signals::try_wake_started_workers;
pub use signals::{cancel_signal, send_signal};
pub use status::{
    diagnostics_report, get_log_level, health_response, record_telemetry, request_shutdown,
    set_log_level, status_report,
};
#[cfg(test)]
pub use task_board::{
    approve_task_board_plan, audit_task_board, begin_task_board_planning, create_task_board_item,
    delete_task_board_item, dispatch_task_board, get_task_board_item, list_task_board_items,
    list_task_board_machines, list_task_board_projects, revoke_task_board_plan,
    submit_task_board_plan, sync_task_board, sync_task_board_async, update_task_board_item,
};
pub(crate) use task_board::{
    audit_policy_pipeline, create_policy_canvas, create_policy_scenario, delete_policy_canvas,
    delete_policy_scenario, dump_policies, duplicate_policy_canvas, export_policy,
    go_live_diff_policy_pipeline, import_policies, import_policy, list_policy_approval_grants,
    make_live_policy_pipeline, policy_canvas_workspace, policy_pipeline, promote_policy_pipeline,
    rename_policy_canvas, replay_policy_pipeline, reset_policy_scenarios,
    resolve_policy_approval_grant, revoke_policy_approval_grant, save_policy_pipeline_draft,
    set_active_policy_canvas, set_policy_canvas_global_enforcement,
    set_policy_canvas_spawn_kill_switch, set_policy_canvas_spawn_requires_live_policy,
    simulate_policy_pipeline, update_policy_scenario,
};
pub(crate) use task_board::{dispatch_task_board_async, pick_task_board_dispatch_async};
pub(crate) use task_board_automation_force_cancel::force_cancel_task_board_automation_db;
pub(crate) use task_board_automation_runtime::{
    TaskBoardAutomationRunSession, TaskBoardAutomationRunStart, task_board_automation_snapshot,
};
pub(crate) use task_board_db::{
    approve_task_board_plan_db, audit_task_board_db, begin_task_board_planning_db,
    create_task_board_item_db, delete_task_board_item_db, get_task_board_item_db,
    get_task_board_item_position_snapshot_db, list_task_board_items_db,
    list_task_board_machines_db, list_task_board_projects_db, reset_task_board_item_position_db,
    revoke_task_board_plan_db, set_task_board_item_position_db, submit_task_board_plan_db,
    sync_task_board_db, task_board_host_list_db, task_board_host_local_db,
    task_board_host_set_project_types_db, touch_task_board_host_local_db,
    update_task_board_item_db,
};
#[cfg(test)]
pub use task_board_evaluation::evaluate_task_board;
pub(crate) use task_board_evaluation::evaluate_task_board_async;
#[cfg(test)]
pub use task_board_host::{
    task_board_host_list, task_board_host_local, task_board_host_set_project_types,
};
#[cfg(test)]
pub use task_board_orchestrator::{
    run_task_board_orchestrator_once, start_task_board_orchestrator, stop_task_board_orchestrator,
    task_board_orchestrator_settings, task_board_orchestrator_status,
    update_task_board_orchestrator_settings,
};
pub(crate) use task_board_orchestrator_control::{
    start_task_board_orchestrator_db, stop_task_board_orchestrator_db,
    task_board_orchestrator_settings_db, task_board_orchestrator_status_db,
    update_task_board_orchestrator_settings_db,
};
pub(crate) use task_board_orchestrator_db::{
    run_task_board_orchestrator_once_db, run_task_board_orchestrator_once_with_session_db,
};
pub(crate) use task_board_orchestrator_run_lease::TaskBoardOrchestratorRunGuard;
pub(crate) use task_board_runtime::{
    acknowledge_task_board_git_runtime_secret_handoff,
    prepare_task_board_git_runtime_secret_handoff, sync_task_board_git_runtime_key_material,
    task_board_git_runtime_config_db, update_task_board_git_runtime_config_db,
    verify_task_board_git_signing_db,
};
pub use task_board_runtime::{
    sync_task_board_github_tokens, sync_task_board_openrouter_token, sync_task_board_todoist_token,
    task_board_git_identity_defaults,
};
#[cfg(test)]
pub use task_board_runtime::{
    task_board_git_runtime_config, update_task_board_git_runtime_config,
    verify_task_board_git_signing,
};
pub use wake_route::WakeDispatch;
pub(crate) use wake_route::{WakeEventLevel, record_wake_event};

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
    list_projects_async, list_sessions_async, reconcile_active_session_liveness_background,
    reconcile_active_session_liveness_background_async, resolve_runtime_session_agent_async,
    resolve_session_for_snapshot, resolve_session_for_snapshot_async, session_acp_transcript_async,
    session_detail_async, session_detail_core_async, session_detail_from_async_daemon_db,
    session_detail_from_daemon_db, session_extensions_async, session_timeline_window_async,
};
pub(crate) use signals_async::{cancel_signal_async, record_signal_ack_direct_async};
pub(crate) use signals_async_send::send_signal_async;
pub(crate) use status::{diagnostics_report_async, github_api_status_async, health_response_async};
pub(crate) use sync_support::{
    acknowledged_signal_record, append_leave_signal_logs_to_db, append_task_drop_effect_logs,
    append_transfer_logs_to_async_db, append_transfer_logs_to_db, build_log_entry,
    build_signal_ack, effective_project_dir, pending_signal_record, project_dir_for_db_session,
    reconcile_expired_pending_signals_for_db, record_signal_ack, refresh_signal_index_for_db,
    resolve_hook_agent, session_not_found, sync_file_state_for_resolved,
    sync_file_state_from_async_db, task_drop_effect_signal_records, write_task_start_signals,
};

#[cfg(test)]
pub(crate) use serve::session_import_required;
#[cfg(test)]
pub(crate) use sessions::{
    build_timeline_window_response, clear_session_liveness_refresh_cache_entry,
    session_liveness_refresh_due_locked, stale_session_ids_for_liveness_refresh,
};
#[cfg(test)]
pub(crate) use status::current_log_level;

#[cfg(test)]
mod tests;
