use std::collections::BTreeMap;
use std::env;
use std::fmt;
use std::path::{Path, PathBuf};
use std::slice;

use chrono::{Duration, Utc};
use serde_json::Value;

use crate::agents::runtime;
use crate::agents::runtime::liveness::LivenessConfig;
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
    acknowledge_signal as write_signal_ack, read_acknowledged_signals, read_acknowledgments,
    read_pending_signals, signal_matches_session,
};
use crate::agents::service as agents_service;
use crate::daemon::client::DaemonClient;
use crate::daemon::index as daemon_index;
use crate::daemon::ordering::sort_session_tasks;
use crate::daemon::protocol;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::workspace::{project_context_dir, utc_now};

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

/// Task-specific fields for `create_task_with_source`.
pub struct TaskSpec<'a> {
    pub title: &'a str,
    pub context: Option<&'a str>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<&'a str>,
    pub source: TaskSource,
    pub observe_issue_id: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ResolvedRuntimeSessionAgent {
    pub orchestration_session_id: String,
    pub agent_id: String,
}

#[derive(Debug, Clone)]
pub(crate) struct LeaveSignalRecord {
    pub(crate) runtime: String,
    pub(crate) agent_id: String,
    pub(crate) signal_session_id: String,
    pub(crate) signal: Signal,
}

#[derive(Debug, Clone)]
pub(crate) enum TaskDropEffect {
    Started(Box<TaskStartSignalRecord>),
    Queued { task_id: String, agent_id: String },
}

#[derive(Debug, Clone)]
pub(crate) struct TaskStartSignalRecord {
    #[expect(
        dead_code,
        reason = "task identity is retained for future task-start signal consumers"
    )]
    pub(crate) task_id: String,
    pub(crate) runtime: String,
    pub(crate) agent_id: String,
    pub(crate) signal_session_id: String,
    pub(crate) signal: Signal,
}

use crate::session::persona;

mod conversions;
mod leader_transfer;
mod lifecycle;
mod liveness;
mod logging;
mod misc;
mod queries;
mod auto_spawn;
mod review_state;
mod review_tasks;
mod routing;
mod runtime_registration;
mod runtime_support;
mod session_helpers;
mod session_state;
mod signal_support;
mod signals;
mod task_queue;
mod task_state;
mod tasks;

#[cfg(test)]
mod tests;

pub(crate) use lifecycle::{apply_leave_session, apply_update_session_title};
pub use lifecycle::{
    assign_role, end_session, join_session, join_session_with_fallback, leave_session,
    remove_agent, start_session, start_session_with_policy, transfer_leader, update_session_title,
};
pub use liveness::{LivenessSyncResult, sync_agent_liveness};
pub use queries::{
    build_recovery_tui_request, list_sessions, list_sessions_global, resolve_session_project_dir,
    session_status,
};
pub use runtime_registration::register_agent_runtime_session;
pub use signals::{
    cancel_signal, list_signals, record_signal_acknowledgment,
    resolve_session_agent_for_runtime_session, send_signal,
};
pub use review_tasks::{
    arbitrate, claim_review, respond_review, submit_for_review, submit_review,
};
pub use tasks::{
    assign_task, create_task, create_task_with_source, drop_task, list_tasks,
    record_task_checkpoint, update_task, update_task_queue_policy,
};

#[allow(unused_imports)]
pub(crate) use conversions::*;
#[allow(unused_imports)]
pub(crate) use leader_transfer::*;
#[allow(unused_imports)]
pub(crate) use liveness::*;
#[allow(unused_imports)]
pub(crate) use logging::*;
#[allow(unused_imports)]
pub(crate) use misc::*;
#[allow(unused_imports)]
pub(crate) use runtime_support::*;
#[allow(unused_imports)]
pub(crate) use session_helpers::*;
#[allow(unused_imports)]
pub(crate) use session_state::*;
#[allow(unused_imports)]
pub(crate) use signal_support::*;
#[allow(unused_imports)]
pub(crate) use auto_spawn::*;
#[allow(unused_imports)]
pub(crate) use review_state::*;
#[allow(unused_imports)]
pub(crate) use routing::*;
#[allow(unused_imports)]
pub(crate) use task_queue::*;
#[allow(unused_imports)]
pub(crate) use task_state::*;
