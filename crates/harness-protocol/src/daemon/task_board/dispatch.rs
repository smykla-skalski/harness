//! `DispatchPlan` and its pure-data closure, relocated here from
//! `harness-task-board::dispatch`. `DispatchAppliedTask`,
//! `DispatchExecutionSummary`, `TaskBoardReadOnlyWorkflowLaunch`, and
//! `TaskBoardWriteWorkflowLaunch` stay behind: they embed the full
//! `TaskBoardItem` domain entity (or types that in turn embed it), which this
//! move has no need for and which reaches state (`TaskBoardPlanningResult`,
//! `TaskBoardPlanApprovalBinding`) that has not moved. `DispatchPlan`'s own
//! `board_item_id` is a plain key, carrying no such closure - the comment on
//! `TaskBoardOrchestratorDispatchOutcome::plans`
//! (`harness-task-board::wire::task_board_orchestrator_status`) already
//! established this. `harness-task-board` re-exports every name below at the
//! same path.

use serde::{Deserialize, Serialize};

use super::dispatch_lifecycle::DispatchLifecycle;
use super::item_fields::ExternalRef;
use super::planning::PlanApprovalBlockReason;
use super::policy_decision::PolicyDecision;
use super::types::{AgentMode, TaskBoardItemKind, TaskBoardStatus};
use crate::session_types::{TaskSeverity, TaskSource};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DispatchPlan {
    pub board_item_id: String,
    #[serde(default)]
    pub rendered_prompt: String,
    pub readiness: DispatchReadiness,
    pub session: SessionIntent,
    pub task: TaskCreationIntent,
    pub worker: WorkerIntent,
    pub reviewer: ReviewerIntent,
    pub evaluator: EvaluatorIntent,
    pub lifecycle: DispatchLifecycle,
    pub policy: PolicyDecision,
    /// Id of the recorded policy decision that produced `policy`, threaded into
    /// reservation so the board workflow stores the real decision id instead of
    /// an unrelated random trace. `None` when the built-in fallback gate decided
    /// (no decision is recorded on that path).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_decision_id: Option<String>,
    /// Id of the durable approval grant this dispatch will consume at reservation.
    /// Set only when an approved live grant matched the spawn evaluation and the
    /// decision allowed; the reservation transaction consumes it one-shot so a
    /// re-dispatch needs a fresh approval. `None` on every non-approval path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_approval_grant_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DispatchFailure {
    pub board_item_id: String,
    pub kind: DispatchFailureKind,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum DispatchFailureKind {
    CreateSession,
    CreateTask,
    LinkItem,
    WorkerSpawnFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum DispatchReadiness {
    Ready,
    Blocked { reason: DispatchBlockReason },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum DispatchBlockReason {
    AlreadyLinked {
        work_item_id: String,
    },
    Deleted,
    MachineMismatch {
        required: Vec<String>,
        declared: Vec<String>,
    },
    PlanApproval {
        reason: PlanApprovalBlockReason,
    },
    Policy {
        decision: PolicyDecision,
    },
    Status {
        status: TaskBoardStatus,
    },
    Kind {
        item_kind: TaskBoardItemKind,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum SessionIntent {
    Existing {
        session_id: String,
    },
    Create {
        title: String,
        context: Option<String>,
        project_id: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskCreationIntent {
    pub title: String,
    pub context: Option<String>,
    pub severity: TaskSeverity,
    pub suggested_fix: Option<String>,
    pub source: TaskSource,
    pub tags: Vec<String>,
    pub external_refs: Vec<ExternalRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct WorkerIntent {
    pub mode: AgentMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewerIntent {
    pub phase: FollowUpPhase,
    pub suggested_persona: String,
    pub required_consensus: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct EvaluatorIntent {
    pub phase: FollowUpPhase,
    pub mode: AgentMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum FollowUpPhase {
    AfterWorkerReview,
}

impl DispatchPlan {
    #[must_use]
    pub const fn is_ready(&self) -> bool {
        matches!(self.readiness, DispatchReadiness::Ready)
    }

    #[must_use]
    pub fn applied_lifecycle(&self) -> DispatchLifecycle {
        self.lifecycle.applied()
    }
}

// Existing coverage for these types stays in
// `harness-task-board::dispatch`'s own `#[path]` test modules, exercised
// through the re-export below.
