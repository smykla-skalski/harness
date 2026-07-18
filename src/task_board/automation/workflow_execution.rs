use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::task_board::{
    TaskBoardAttemptState, TaskBoardEvaluationResult, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardImplementationResult,
    TaskBoardLifecycleOutcome, TaskBoardPlanApprovalBinding, TaskBoardPlanApprovalInvalidation,
    TaskBoardPlanningResult, TaskBoardResolvedReviewer, TaskBoardReviewRoundDecision,
    TaskBoardReviewerOutcome, TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
};

pub const TASK_BOARD_WORKFLOW_EXECUTION_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS: i64 = 300;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardExecutionDiagnostic {
    pub code: String,
    pub message: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardReviewCycle {
    pub revision_cycle: u32,
    pub head_revision: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outcomes: Vec<TaskBoardReviewerOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<TaskBoardReviewRoundDecision>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardRetrySchedule {
    pub action_key: String,
    pub next_attempt: u32,
    pub failure_class: TaskBoardFailureClass,
    pub available_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardTerminalOutcomeKind {
    Succeeded,
    Failed,
    Cancelled,
    HumanRequired,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardTerminalOutcome {
    pub kind: TaskBoardTerminalOutcomeKind,
    pub summary: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowExecutionArtifacts {
    pub schema_version: u32,
    pub current_revision_cycle: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning_result: Option<TaskBoardPlanningResult>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_approval: Option<TaskBoardPlanApprovalBinding>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub approval_invalidations: Vec<TaskBoardPlanApprovalInvalidation>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub review_cycles: Vec<TaskBoardReviewCycle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry: Option<TaskBoardRetrySchedule>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<TaskBoardExecutionDiagnostic>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_outcome: Option<TaskBoardTerminalOutcome>,
}

impl Default for TaskBoardWorkflowExecutionArtifacts {
    fn default() -> Self {
        Self {
            schema_version: TASK_BOARD_WORKFLOW_EXECUTION_SCHEMA_VERSION,
            current_revision_cycle: 1,
            planning_result: None,
            plan_approval: None,
            approval_invalidations: Vec::new(),
            review_cycles: Vec::new(),
            retry: None,
            diagnostics: Vec::new(),
            terminal_outcome: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardExecutionOwnership {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<String>,
    pub fencing_epoch: u64,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub resources: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum TaskBoardAttemptResultArtifact {
    Planning(TaskBoardPlanningResult),
    Implementation(TaskBoardImplementationResult),
    Review(TaskBoardReviewerOutcome),
    Evaluation(TaskBoardEvaluationResult),
    Lifecycle(TaskBoardLifecycleOutcome),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardLocalAttemptResult {
    pub schema_version: u32,
    pub execution_id: String,
    pub action_key: String,
    pub attempt: u32,
    pub idempotency_key: String,
    pub exact_head_revision: String,
    pub artifact: TaskBoardAttemptResultArtifact,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardExecutionAttemptRecord {
    pub execution_id: String,
    pub action_key: String,
    pub attempt: u32,
    pub idempotency_key: String,
    pub state: TaskBoardAttemptState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_class: Option<TaskBoardFailureClass>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<TaskBoardAttemptResultArtifact>,
    pub started_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowExecutionRecord {
    pub execution_id: String,
    pub item_id: String,
    pub snapshot: TaskBoardWorkflowSnapshot,
    pub resolved_reviewers: TaskBoardResolvedReviewer,
    pub transition: TaskBoardWorkflowTransitionState,
    pub artifacts: TaskBoardWorkflowExecutionArtifacts,
    pub ownership: TaskBoardExecutionOwnership,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attempts: Vec<TaskBoardExecutionAttemptRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowRevisionGuard {
    pub item_revision: i64,
    pub configuration_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
}

impl From<&TaskBoardWorkflowSnapshot> for TaskBoardWorkflowRevisionGuard {
    fn from(snapshot: &TaskBoardWorkflowSnapshot) -> Self {
        Self {
            item_revision: snapshot.item_revision,
            configuration_revision: snapshot.configuration_revision,
            provider_revision: snapshot.provider_revision.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowExecutionCas {
    pub execution_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<TaskBoardExecutionPhase>,
    pub state: TaskBoardExecutionState,
    pub revisions: TaskBoardWorkflowRevisionGuard,
    pub record_sha256: String,
}

impl From<&TaskBoardWorkflowExecutionRecord> for TaskBoardWorkflowExecutionCas {
    fn from(record: &TaskBoardWorkflowExecutionRecord) -> Self {
        Self {
            execution_id: record.execution_id.clone(),
            phase: record.transition.phase,
            state: record.transition.execution_state,
            revisions: TaskBoardWorkflowRevisionGuard::from(&record.snapshot),
            record_sha256: workflow_execution_sha256(record),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkflowCasMismatch {
    ExecutionId,
    Phase,
    State,
    ItemRevision,
    ConfigurationRevision,
    ProviderRevision,
    Record,
}

fn workflow_execution_sha256(record: &TaskBoardWorkflowExecutionRecord) -> String {
    let canonical =
        serde_json::to_vec(record).expect("workflow execution record serialization is infallible");
    hex::encode(Sha256::digest(canonical))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardWorkflowExecutionCreateOutcome {
    pub execution: TaskBoardWorkflowExecutionRecord,
    pub created: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardWorkflowExecutionCasOutcome {
    Updated(TaskBoardWorkflowExecutionRecord),
    Unchanged(TaskBoardWorkflowExecutionRecord),
    Stale {
        mismatch: TaskBoardWorkflowCasMismatch,
        current: Option<TaskBoardWorkflowExecutionRecord>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardExecutionAttemptCas {
    pub execution_id: String,
    pub action_key: String,
    pub attempt: u32,
    pub idempotency_key: String,
    pub state: TaskBoardAttemptState,
}

impl From<&TaskBoardExecutionAttemptRecord> for TaskBoardExecutionAttemptCas {
    fn from(record: &TaskBoardExecutionAttemptRecord) -> Self {
        Self {
            execution_id: record.execution_id.clone(),
            action_key: record.action_key.clone(),
            attempt: record.attempt,
            idempotency_key: record.idempotency_key.clone(),
            state: record.state,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardExecutionAttemptCreateOutcome {
    pub attempt: TaskBoardExecutionAttemptRecord,
    pub created: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardExecutionAttemptCasOutcome {
    Updated(TaskBoardExecutionAttemptRecord),
    Unchanged(TaskBoardExecutionAttemptRecord),
    Stale(Option<TaskBoardExecutionAttemptRecord>),
}
