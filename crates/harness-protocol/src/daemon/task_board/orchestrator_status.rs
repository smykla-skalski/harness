//! The orchestrator's thin wire status, relocated here from
//! `harness-task-board::wire::task_board_orchestrator_status`. That module's
//! own doc comment already explains why this projection stays apart from
//! `TaskBoardOrchestratorStatusSnapshot`: the daemon's wire contract must
//! never embed `TaskBoardItem` or the internal-only `DispatchAppliedTask`/
//! `TaskBoardEvaluationRecord` fields, which is exactly what makes every type
//! here pure data. The five `From` impls that build these types out of their
//! fat `harness-task-board`-only counterparts could not come along - `Self`
//! (the target of each `From`) would no longer be local to either crate - so
//! they stayed behind as free functions (`task_board_orchestrator_status_from_snapshot`
//! and friends) in `harness-task-board`, alongside the fixture-based tests
//! that exercise them. `harness-task-board` re-exports every type name below
//! at the same path.

use serde::{Deserialize, Serialize};

use super::automation_snapshot::TaskBoardAutomationSnapshot;
use super::dispatch::{DispatchFailure, DispatchPlan};
use super::evaluation::{EvaluationSignalFailure, TaskBoardEvaluationOutcome};
use super::orchestrator::{
    TaskBoardHeldDispatchSummary, TaskBoardOrchestratorRunStatus, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorTickInfo, TaskBoardWorkflowExecutionCount,
};
use super::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
use super::types::{TaskBoardStatus, TaskBoardWorkflowStatus};
use crate::session_types::TaskStatus;

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorStatus {
    pub enabled: bool,
    pub running: bool,
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default)]
    pub held_dispatches: TaskBoardHeldDispatchSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tick: Option<TaskBoardOrchestratorTickInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<TaskBoardOrchestratorRunOutcome>,
    pub workflow_execution_counts: Vec<TaskBoardWorkflowExecutionCount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation: Option<TaskBoardAutomationSnapshot>,
    pub settings: TaskBoardOrchestratorSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorRunOutcome {
    pub run_id: String,
    pub started_at: String,
    pub completed_at: String,
    pub status: TaskBoardOrchestratorRunStatus,
    pub dry_run: bool,
    pub sync: TaskBoardSyncSummary,
    pub audit: TaskBoardAuditSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch: Option<TaskBoardOrchestratorDispatchOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evaluation: Option<TaskBoardOrchestratorEvaluationOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

/// Thin mirror of `DispatchExecutionSummary`. `plans` rides through
/// unchanged: `DispatchPlan` names no `TaskBoardItem`, only a `board_item_id`
/// key, so it carries no domain-entity closure to strip.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorDispatchOutcome {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub plans: Vec<DispatchPlan>,
    pub applied: Vec<TaskBoardOrchestratorAppliedTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<DispatchFailure>,
}

/// Thin mirror of `DispatchAppliedTask`: drops the embedded `TaskBoardItem`
/// (keeping only its title, the one field real consumers read off it) and
/// the `lifecycle`/`read_only_workflow`/`write_workflow` fields, which are
/// daemon-internal worker-claim bookkeeping that Swift already omits on
/// decode for the direct dispatch endpoint.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorAppliedTask {
    pub board_item_id: String,
    pub session_id: String,
    pub work_item_id: String,
    pub item_title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorEvaluationOutcome {
    pub total: usize,
    pub evaluated: usize,
    pub updated: usize,
    pub skipped: usize,
    pub completed: usize,
    pub running: usize,
    pub reviewing: usize,
    pub blocked: usize,
    pub failed: usize,
    pub records: Vec<TaskBoardOrchestratorEvaluationRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signal_failures: Vec<EvaluationSignalFailure>,
}

/// Thin mirror of `TaskBoardEvaluationRecord`: `item: Option<TaskBoardItem>`
/// becomes `item_title: Option<String>`, the only piece of it any consumer of
/// this specific embedding reads.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorEvaluationRecord {
    pub board_item_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    pub outcome: TaskBoardEvaluationOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_status: Option<TaskStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_status: Option<TaskBoardWorkflowStatus>,
    #[serde(default)]
    pub updated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_title: Option<String>,
}

impl TaskBoardOrchestratorStatus {
    #[must_use]
    pub fn last_run_applied_count(&self) -> usize {
        self.last_run.as_ref().map_or(0, |run| {
            let synced = run
                .sync
                .operations
                .iter()
                .filter(|operation| operation.applied)
                .count();
            let dispatched = run
                .dispatch
                .as_ref()
                .map_or(0, |dispatch| dispatch.applied.len());
            let evaluated = run
                .evaluation
                .as_ref()
                .map_or(0, |evaluation| evaluation.updated);
            synced + dispatched + evaluated
        })
    }
}

// The `From<TaskBoardOrchestratorStatusSnapshot>`/`From<TaskBoardOrchestratorRunSummary>`/
// `From<DispatchExecutionSummary>`/`From<DispatchAppliedTask>`/
// `From<TaskBoardEvaluationSummary>`/`From<TaskBoardEvaluationRecord>` impls,
// and the fixture-based tests that exercise them, stay in
// `harness-task-board::wire::task_board_orchestrator_status` as free
// functions - see that module's own doc comment.
