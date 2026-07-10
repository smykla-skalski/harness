use serde::{Deserialize, Serialize};

use crate::session::types::{ReviewVerdict, TaskStatus, WorkItem};

use super::types::{
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowState, TaskBoardWorkflowStatus,
};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardEvaluationSummary {
    pub total: usize,
    pub evaluated: usize,
    pub updated: usize,
    pub skipped: usize,
    pub completed: usize,
    pub running: usize,
    pub reviewing: usize,
    pub blocked: usize,
    pub failed: usize,
    pub records: Vec<TaskBoardEvaluationRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signal_failures: Vec<EvaluationSignalFailure>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvaluationSignalFailure {
    pub board_item_id: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardEvaluationRecord {
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
    pub item: Option<TaskBoardItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardEvaluationOutcome {
    SkippedUnlinked,
    MissingSession,
    MissingTask,
    WorkerPending,
    WorkerRunning,
    ReviewPending,
    ReviewRunning,
    ReviewChangesRequested,
    Completed,
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardEvaluationDecision {
    pub outcome: TaskBoardEvaluationOutcome,
    pub task_status: TaskStatus,
    pub status: TaskBoardStatus,
    pub workflow: TaskBoardWorkflowState,
    pub reason: Option<String>,
}

impl TaskBoardEvaluationSummary {
    pub fn push(&mut self, record: TaskBoardEvaluationRecord) {
        self.total += 1;
        if record.updated {
            self.updated += 1;
        }
        match record.outcome {
            TaskBoardEvaluationOutcome::SkippedUnlinked => {
                self.skipped += 1;
            }
            TaskBoardEvaluationOutcome::MissingSession
            | TaskBoardEvaluationOutcome::MissingTask => {
                self.evaluated += 1;
                self.failed += 1;
            }
            TaskBoardEvaluationOutcome::WorkerPending
            | TaskBoardEvaluationOutcome::WorkerRunning => {
                self.evaluated += 1;
                self.running += 1;
            }
            TaskBoardEvaluationOutcome::ReviewPending
            | TaskBoardEvaluationOutcome::ReviewRunning
            | TaskBoardEvaluationOutcome::ReviewChangesRequested => {
                self.evaluated += 1;
                self.reviewing += 1;
            }
            TaskBoardEvaluationOutcome::Completed => {
                self.evaluated += 1;
                self.completed += 1;
            }
            TaskBoardEvaluationOutcome::Blocked => {
                self.evaluated += 1;
                self.blocked += 1;
            }
        }
        self.records.push(record);
    }
}

#[must_use]
pub fn evaluate_task_board_item(
    item: &TaskBoardItem,
    task: &WorkItem,
) -> TaskBoardEvaluationDecision {
    match task.status {
        TaskStatus::Open => running_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::WorkerPending,
            TaskBoardStatus::InProgress,
            "worker_pending",
            None,
        ),
        TaskStatus::InProgress => running_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::WorkerRunning,
            TaskBoardStatus::InProgress,
            "worker",
            None,
        ),
        TaskStatus::AwaitingReview => running_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::ReviewPending,
            TaskBoardStatus::ToReview,
            "review_pending",
            None,
        ),
        TaskStatus::InReview => in_review_decision(item, task),
        TaskStatus::Done => terminal_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::Completed,
            TaskBoardStatus::Done,
            TaskBoardWorkflowStatus::Completed,
            "completed",
            None,
        ),
        TaskStatus::Blocked => terminal_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::Blocked,
            TaskBoardStatus::Failed,
            TaskBoardWorkflowStatus::Failed,
            "blocked",
            Some(
                task.blocked_reason
                    .clone()
                    .unwrap_or_else(|| "session task blocked".to_string()),
            ),
        ),
    }
}

#[must_use]
pub fn missing_session_record(item: &TaskBoardItem, reason: String) -> TaskBoardEvaluationRecord {
    missing_record(
        item,
        TaskBoardEvaluationOutcome::MissingSession,
        "missing_session",
        reason,
    )
}

#[must_use]
pub fn missing_task_record(item: &TaskBoardItem, reason: String) -> TaskBoardEvaluationRecord {
    missing_record(
        item,
        TaskBoardEvaluationOutcome::MissingTask,
        "missing_task",
        reason,
    )
}

#[must_use]
pub fn skipped_unlinked_record(item: &TaskBoardItem) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord {
        board_item_id: item.id.clone(),
        session_id: item.session_id.clone(),
        work_item_id: item.work_item_id.clone(),
        outcome: TaskBoardEvaluationOutcome::SkippedUnlinked,
        task_status: None,
        board_status: Some(item.status),
        workflow_status: Some(item.workflow.status),
        updated: false,
        reason: Some("board item is not linked to a session task".to_string()),
        item: None,
    }
}

#[must_use]
pub fn record_from_decision(
    item: &TaskBoardItem,
    decision: &TaskBoardEvaluationDecision,
    updated: bool,
    updated_item: Option<TaskBoardItem>,
) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord {
        board_item_id: item.id.clone(),
        session_id: item.session_id.clone(),
        work_item_id: item.work_item_id.clone(),
        outcome: decision.outcome,
        task_status: Some(decision.task_status),
        board_status: Some(decision.status),
        workflow_status: Some(decision.workflow.status),
        updated,
        reason: decision.reason.clone(),
        item: updated_item,
    }
}

#[must_use]
pub fn failed_workflow(item: &TaskBoardItem, step: &str, reason: String) -> TaskBoardWorkflowState {
    let mut workflow = item.workflow.clone();
    workflow.status = TaskBoardWorkflowStatus::Failed;
    workflow.current_step_id = Some(step.to_string());
    workflow.last_error = Some(reason);
    workflow
}

fn running_decision(
    item: &TaskBoardItem,
    task: &WorkItem,
    outcome: TaskBoardEvaluationOutcome,
    status: TaskBoardStatus,
    step: &str,
    reason: Option<String>,
) -> TaskBoardEvaluationDecision {
    terminal_decision(
        item,
        task,
        outcome,
        status,
        TaskBoardWorkflowStatus::Running,
        step,
        reason,
    )
}

fn in_review_decision(item: &TaskBoardItem, task: &WorkItem) -> TaskBoardEvaluationDecision {
    if let Some(consensus) = &task.consensus
        && !matches!(consensus.verdict, ReviewVerdict::Approve)
    {
        return running_decision(
            item,
            task,
            TaskBoardEvaluationOutcome::ReviewChangesRequested,
            TaskBoardStatus::InReview,
            "review_changes_requested",
            (!consensus.summary.is_empty()).then(|| consensus.summary.clone()),
        );
    }
    running_decision(
        item,
        task,
        TaskBoardEvaluationOutcome::ReviewRunning,
        TaskBoardStatus::InReview,
        "review",
        None,
    )
}

fn terminal_decision(
    item: &TaskBoardItem,
    task: &WorkItem,
    outcome: TaskBoardEvaluationOutcome,
    status: TaskBoardStatus,
    workflow_status: TaskBoardWorkflowStatus,
    step: &str,
    reason: Option<String>,
) -> TaskBoardEvaluationDecision {
    let mut workflow = item.workflow.clone();
    workflow.status = workflow_status;
    workflow.current_step_id = Some(step.to_string());
    workflow.last_error.clone_from(&reason);
    TaskBoardEvaluationDecision {
        outcome,
        task_status: task.status,
        status,
        workflow,
        reason,
    }
}

fn missing_record(
    item: &TaskBoardItem,
    outcome: TaskBoardEvaluationOutcome,
    step: &str,
    reason: String,
) -> TaskBoardEvaluationRecord {
    let workflow = failed_workflow(item, step, reason.clone());
    TaskBoardEvaluationRecord {
        board_item_id: item.id.clone(),
        session_id: item.session_id.clone(),
        work_item_id: item.work_item_id.clone(),
        outcome,
        task_status: None,
        board_status: Some(TaskBoardStatus::Failed),
        workflow_status: Some(workflow.status),
        updated: false,
        reason: Some(reason),
        item: None,
    }
}

#[cfg(test)]
mod tests {
    use crate::session::types::{TaskSeverity, TaskSource};

    use super::*;

    fn item() -> TaskBoardItem {
        let mut item = TaskBoardItem::new(
            "board-1".to_string(),
            "Board item".to_string(),
            String::new(),
            "2026-05-14T00:00:00Z".to_string(),
        );
        item.workflow.execution_id = Some("workflow-1".to_string());
        item.workflow.attempts = 2;
        item.workflow.policy_trace_ids = vec!["trace-1".to_string()];
        item
    }

    fn task(status: TaskStatus) -> WorkItem {
        WorkItem {
            task_id: "task-1".to_string(),
            title: "Session task".to_string(),
            context: None,
            severity: TaskSeverity::Medium,
            status,
            assigned_to: None,
            queue_policy: Default::default(),
            queued_at: None,
            created_at: "2026-05-14T00:00:00Z".to_string(),
            updated_at: "2026-05-14T00:00:00Z".to_string(),
            created_by: None,
            notes: Vec::new(),
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
            awaiting_review: None,
            review_claim: None,
            consensus: None,
            review_history: Vec::new(),
            review_round: 0,
            arbitration: None,
            suggested_persona: None,
            deleted_at: None,
        }
    }

    #[test]
    fn completed_task_closes_board_workflow() {
        let decision = evaluate_task_board_item(&item(), &task(TaskStatus::Done));

        assert_eq!(decision.outcome, TaskBoardEvaluationOutcome::Completed);
        assert_eq!(decision.status, TaskBoardStatus::Done);
        assert_eq!(decision.workflow.status, TaskBoardWorkflowStatus::Completed);
        assert_eq!(
            decision.workflow.current_step_id.as_deref(),
            Some("completed")
        );
        assert_eq!(
            decision.workflow.execution_id.as_deref(),
            Some("workflow-1")
        );
        assert_eq!(decision.workflow.attempts, 2);
        assert_eq!(decision.workflow.policy_trace_ids, ["trace-1"]);
        assert!(decision.workflow.last_error.is_none());
    }

    #[test]
    fn blocked_task_marks_board_failed_with_reason() {
        let mut task = task(TaskStatus::Blocked);
        task.blocked_reason = Some("needs human decision".to_string());

        let decision = evaluate_task_board_item(&item(), &task);

        assert_eq!(decision.outcome, TaskBoardEvaluationOutcome::Blocked);
        assert_eq!(decision.status, TaskBoardStatus::Failed);
        assert_eq!(decision.workflow.status, TaskBoardWorkflowStatus::Failed);
        assert_eq!(
            decision.workflow.current_step_id.as_deref(),
            Some("blocked")
        );
        assert_eq!(decision.reason.as_deref(), Some("needs human decision"));
        assert_eq!(
            decision.workflow.last_error.as_deref(),
            Some("needs human decision")
        );
    }

    #[test]
    fn review_change_consensus_stays_in_review() {
        let mut task = task(TaskStatus::InReview);
        task.consensus = Some(crate::session::types::ReviewConsensus {
            verdict: ReviewVerdict::RequestChanges,
            summary: "Needs one fix".to_string(),
            points: Vec::new(),
            closed_at: "2026-05-14T00:01:00Z".to_string(),
            reviewer_agent_ids: vec!["reviewer-1".to_string()],
        });

        let decision = evaluate_task_board_item(&item(), &task);

        assert_eq!(
            decision.outcome,
            TaskBoardEvaluationOutcome::ReviewChangesRequested
        );
        assert_eq!(decision.status, TaskBoardStatus::InReview);
        assert_eq!(decision.workflow.status, TaskBoardWorkflowStatus::Running);
        assert_eq!(
            decision.workflow.current_step_id.as_deref(),
            Some("review_changes_requested")
        );
        assert_eq!(decision.reason.as_deref(), Some("Needs one fix"));
    }
}
