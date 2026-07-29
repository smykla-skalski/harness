use std::collections::BTreeMap;
use std::env;
use std::fmt;
use std::path::{Path, PathBuf};
use std::slice;

use chrono::{Duration, Utc};
use serde_json::Value;

use crate::ordering::sort_session_tasks;
use crate::wire;
use harness_agents::runtime;
use harness_agents::runtime::liveness::LivenessConfig;
use harness_agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
    acknowledge_signal as write_signal_ack, read_acknowledged_signals, read_acknowledgments,
    read_pending_signals, signal_matches_session,
};
use harness_agents::service as agents_service;
use harness_daemon_client::ClientError;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::agent::HookAgent;
use harness_workspace::workspace::{project_context_dir, utc_now};

use super::index as session_index;
use super::roles::{SessionAction, is_permitted};
use super::storage;
use super::types::{
    AgentRegistration, AgentStatus, AwaitingReview, CONTROL_PLANE_ACTOR_ID, CURRENT_VERSION,
    PendingLeaderTransfer, SessionMetrics, SessionRole, SessionSignalRecord, SessionSignalStatus,
    SessionState, SessionStatus, SessionTransition, TaskCheckpoint, TaskCheckpointSummary,
    TaskNote, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus, WorkItem,
};

const DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS: i64 = 300;
const LEAVE_SESSION_SIGNAL_COMMAND: &str = "abort";
const END_SESSION_SIGNAL_MESSAGE: &str =
    "This harness session has ended. Stop current work and leave the harness session.";
const REMOVE_AGENT_SIGNAL_MESSAGE: &str = "You have been removed from this harness session. Stop current work and leave the harness session.";
const END_SESSION_SIGNAL_ACTION_HINT: &str = "harness:session:end";
const REMOVE_AGENT_SIGNAL_ACTION_HINT: &str = "harness:session:remove-agent";
const START_TASK_SIGNAL_COMMAND: &str = "request_action";

/// Map a leaf `harness-daemon-client` transport failure onto the domain's own
/// error type, shared by every submodule that talks to the daemon directly.
#[must_use]
pub fn daemon_client_error(operation: &str, error: &ClientError) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "daemon {operation}: {error}"
    )))
}

/// Task-specific fields for `create_task_with_source`.
pub struct TaskSpec<'a> {
    pub title: &'a str,
    pub context: Option<&'a str>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<&'a str>,
    pub source: TaskSource,
    pub observe_issue_id: Option<&'a str>,
}

pub use harness_protocol::session_wire::ResolvedRuntimeSessionAgent;

// `pub`, not `pub(crate)`: the root crate's `daemon::service` reads these
// fields directly across the crate boundary (sync, wake-route, and logging
// support all match on the daemon-managed signal shapes).
#[derive(Debug, Clone)]
pub struct LeaveSignalRecord {
    pub runtime: String,
    pub agent_id: String,
    pub signal_session_id: String,
    pub signal: Signal,
}

#[derive(Debug, Clone)]
pub enum TaskDropEffect {
    Started(Box<TaskStartSignalRecord>),
    Queued { task_id: String, agent_id: String },
}

#[derive(Debug, Clone)]
pub struct TaskStartSignalRecord {
    // No in-crate reader: task identity is retained for future task-start
    // signal consumers. Genuinely `pub` now, so rustc no longer flags this
    // as dead code the way it did while the struct was `pub(crate)`.
    pub task_id: String,
    pub runtime: String,
    pub agent_id: String,
    pub signal_session_id: String,
    pub signal: Signal,
}

use crate::persona;

mod auto_spawn;
mod conversions;
mod improver_state;
mod leader_transfer;
mod lifecycle;
mod liveness;
mod logging;
mod misc;
mod queries;
mod review_state;
mod review_tasks;
mod routing;
mod runtime_registration;
mod runtime_support;
mod session_exit;
mod session_helpers;
mod session_state;
mod signal_support;
mod signals;
mod task_assignment;
mod task_delete;
mod task_queue;
mod task_state;
mod tasks;

#[cfg(test)]
mod tests;

// `pub`, not `pub(crate)`: `daemon::service::leave` and `daemon::service::direct`
// in the root crate call these directly for daemon-managed sessions.
#[cfg(any(test, feature = "daemon-runtime"))]
pub use lifecycle::{apply_leave_session, apply_update_session_title};
pub use lifecycle::{
    assign_role, end_session, join_session, join_session_with_fallback, leave_session,
    remove_agent, start_session, start_session_with_policy, transfer_leader, update_session_title,
};
pub use liveness::{LivenessSyncResult, sync_agent_liveness};
pub use queries::{
    build_recovery_tui_request, list_sessions, list_sessions_global, resolve_session_project_dir,
    session_agent_is_alive, session_status,
};
pub use review_tasks::{
    arbitrate, claim_review, respond_review, submit_for_review, submit_for_review_with_persona,
    submit_review,
};
pub use runtime_registration::register_agent_runtime_session;
pub use signals::{
    cancel_signal, list_signals, record_signal_acknowledgment,
    resolve_session_agent_for_runtime_session, send_signal,
};
pub use tasks::{
    assign_task, create_task, create_task_with_source, delete_task, drop_task, list_tasks,
    record_task_checkpoint, update_task, update_task_queue_policy,
};

// The submodules below are private (`mod`, not `pub mod`) and re-exported
// here with a blanket `pub use`. The root crate's `daemon::*` reaches deep
// into this domain's internals - mutation appliers, signal-record fields,
// logging builders - the same way other in-workspace callers did before this
// module was its own crate, so nearly every item here is part of the real
// cross-crate surface rather than a handful of hand-picked exceptions.
pub use auto_spawn::*;
pub use conversions::*;
pub use improver_state::{
    ImproverApplyOutcome, ImproverTarget, apply_improver_apply, improver_apply,
    preview_improver_apply, validate_skill_patch_path,
};
pub use leader_transfer::*;
pub use liveness::*;
pub use logging::*;
pub use misc::*;
pub use review_state::*;
pub use routing::*;
pub use runtime_support::*;
pub use session_exit::*;
pub use session_helpers::*;
pub use session_state::*;
// The session-index test suite in `harness-session` fixtures sessions
// through this, so it needs a real `pub` path rather than the crate-only
// glob above.
pub use session_state::build_new_session_with_policy;
pub use signal_support::*;
pub use task_assignment::*;
pub use task_delete::*;
pub use task_queue::*;
pub use task_state::*;
