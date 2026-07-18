use serde::{Deserialize, Serialize};

use crate::task_board::{ExternalRefProvider, TaskBoardReviewerProfile};

pub const TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkflowKind {
    Unknown,
    #[default]
    DefaultTask,
    PrFix,
    PrReview,
    Review,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardExecutionPhase {
    #[default]
    Planning,
    AwaitingApproval,
    Implementation,
    Review,
    Evaluate,
    Publish,
    Cleanup,
    Terminal,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardExecutionState {
    #[default]
    Pending,
    Preparing,
    Starting,
    Running,
    RetryWait,
    AwaitingApproval,
    Blocked,
    HumanRequired,
    Draining,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAttemptState {
    Preparing,
    Starting,
    Running,
    RetryWait,
    Completed,
    Failed,
    Cancelled,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardFailureClass {
    Transient,
    Permanent,
    Authentication,
    Configuration,
    Policy,
    Conflict,
    UnknownOutcome,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardPhaseVerdict {
    Pass,
    ChangesRequired,
    HumanRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardPhaseCapabilityProfile {
    PlanningReadOnly,
    ImplementationWrite,
    ReviewReadOnly,
    EvaluateReadOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPlanningResult {
    pub plan_markdown: String,
    pub acceptance_criteria: Vec<String>,
    pub plan_hash: String,
    pub item_revision: i64,
    pub configuration_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardReviewResult {
    pub verdict: TaskBoardPhaseVerdict,
    pub head_revision: String,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub findings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardImplementationResult {
    pub revision_cycle: u32,
    pub base_head_revision: String,
    pub head_revision: String,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardEvaluationResult {
    pub verdict: TaskBoardPhaseVerdict,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evidence: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision_cycle: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardResolvedReviewer {
    pub reviewer_count: u32,
    pub required_approvals: u32,
    pub max_revision_cycles: u32,
    pub profiles: Vec<TaskBoardReviewerProfile>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardReadOnlyRunContext {
    pub schema_version: u32,
    pub session_id: String,
    pub title: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    pub worktree: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWorkflowSnapshot {
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    pub item_revision: i64,
    pub configuration_revision: u64,
    pub policy_version: String,
    pub reviewer: TaskBoardResolvedReviewer,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_only_run_context: Option<TaskBoardReadOnlyRunContext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAdmissionRequirementKind {
    Concurrency,
    Rate,
    TimeWindow,
    TokenBudget,
    MonetaryBudget,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAdmissionRequirement {
    pub kind: TaskBoardAdmissionRequirementKind,
    pub scope: String,
    pub limit: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reservation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_at: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardConflictState {
    Open,
    ResolvedLocal,
    ResolvedRemote,
    ResolvedMerged,
    Superseded,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardSyncConflict {
    pub conflict_id: String,
    pub item_id: String,
    pub provider: ExternalRefProvider,
    pub external_ref: String,
    pub field: String,
    pub base_value: serde_json::Value,
    pub local_value: serde_json::Value,
    pub remote_value: serde_json::Value,
    pub item_revision: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
    pub state: TaskBoardConflictState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardLifecycleRequest {
    pub execution_id: String,
    pub item_id: String,
    pub phase: TaskBoardExecutionPhase,
    pub snapshot: TaskBoardWorkflowSnapshot,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardLifecycleOutcome {
    pub mutated: bool,
    pub terminal: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_url: Option<String>,
}
