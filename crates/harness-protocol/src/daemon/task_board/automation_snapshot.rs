//! Task-board automation runtime snapshot, relocated here unchanged from
//! `harness-task-board::automation::status`. Pure data plus pure inherent
//! methods (`normalized_limit`'s clamp, `has_same_binding`'s field compare);
//! `harness-task-board` re-exports every name below at the same path.

use serde::{Deserialize, Serialize};

use super::item_fields::ExternalRefProvider;
use super::item_intent::TaskBoardWorkflowKind;
use super::types::TaskBoardStatus;

const LEGACY_TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationDesiredMode {
    #[default]
    Off,
    Continuous,
    Step,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationAdmissionState {
    Accepting,
    Draining,
    #[default]
    Stopped,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationEffectiveState {
    Offline,
    #[default]
    Idle,
    Scheduled,
    Running,
    BackingOff,
    Stopping,
    Degraded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationRunTrigger {
    Scheduled,
    Event,
    Manual,
    Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationRunState {
    Running,
    Cancelling,
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardAutomationRunOutcome {
    Completed,
    Noop,
    Partial,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationScope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<ExternalRefProvider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationQueueSummary {
    pub ready: usize,
    pub awaiting_approval: usize,
    pub policy_blocked: usize,
    pub preparing: usize,
    pub retrying: usize,
    pub starting: usize,
    pub active: usize,
    pub draining: usize,
    pub cleanup_required: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationRunInfo {
    pub run_id: String,
    pub trigger: TaskBoardAutomationRunTrigger,
    pub state: TaskBoardAutomationRunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<TaskBoardAutomationRunOutcome>,
    pub dry_run: bool,
    pub scope: TaskBoardAutomationScope,
    pub started_at: String,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
pub struct TaskBoardAutomationHistoryRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
}

impl TaskBoardAutomationHistoryRequest {
    #[must_use]
    pub fn normalized_limit(&self) -> u32 {
        self.limit.unwrap_or(100).clamp(1, 500)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationHistoryResponse {
    pub runs: Vec<TaskBoardAutomationRunInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
    pub has_older: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationRunStage {
    pub sequence: u64,
    pub stage: String,
    pub state: String,
    pub recorded_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(value_type = Option<Object>)]
    pub payload: Option<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationRunDetail {
    pub run: TaskBoardAutomationRunInfo,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stages: Vec<TaskBoardAutomationRunStage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationMetrics {
    pub runs_total: u64,
    pub runs_running: u64,
    pub runs_completed: u64,
    pub runs_noop: u64,
    pub runs_partial: u64,
    pub runs_failed: u64,
    pub runs_cancelled: u64,
    pub open_conflicts: u64,
    pub captured_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationCancelTarget {
    pub execution_id: String,
    pub item_id: String,
    pub workflow_kind: TaskBoardWorkflowKind,
    pub assignment_id: String,
    pub host_id: String,
    pub fencing_epoch: u64,
    pub action_key: String,
    pub attempt: u32,
    pub idempotency_key: String,
    pub assignment_state: String,
    pub expected_record_sha256: String,
    pub cancel_pending: bool,
}

impl TaskBoardAutomationCancelTarget {
    #[must_use]
    pub fn has_same_binding(&self, other: &Self) -> bool {
        self.execution_id == other.execution_id
            && self.item_id == other.item_id
            && self.workflow_kind == other.workflow_kind
            && self.assignment_id == other.assignment_id
            && self.host_id == other.host_id
            && self.fencing_epoch == other.fencing_epoch
            && self.action_key == other.action_key
            && self.attempt == other.attempt
            && self.idempotency_key == other.idempotency_key
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationSnapshot {
    #[serde(default = "default_snapshot_schema_version")]
    pub schema_version: u32,
    pub revision: u64,
    pub desired_mode: TaskBoardAutomationDesiredMode,
    pub admission_state: TaskBoardAutomationAdmissionState,
    pub effective_state: TaskBoardAutomationEffectiveState,
    pub observed_at: String,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heartbeat_age_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_retry_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_success_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_reconciliation_at: Option<String>,
    pub settings_revision: u64,
    pub policy_revision: u64,
    pub queue: TaskBoardAutomationQueueSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_run: Option<TaskBoardAutomationRunInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cancelable_targets: Vec<TaskBoardAutomationCancelTarget>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub cancelable_targets_truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
}

const fn default_snapshot_schema_version() -> u32 {
    LEGACY_TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if requires a function taking `&T`"
)]
const fn is_false(value: &bool) -> bool {
    !*value
}

// Existing coverage for these types stays in
// `harness-task-board::automation::status`'s own test module, exercised
// through the re-export below.
