use serde::{Deserialize, Serialize};

use harness_session::types::{ReviewVerdict, TaskStatus, WorkItem};

use super::types::{
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowState, TaskBoardWorkflowStatus,
};
use super::work_item_progress::{TaskBoardWorkItemProgress, TaskBoardWorkItemState};

// `TaskBoardEvaluationOutcome`/`EvaluationSignalFailure` relocated to
// `harness_protocol::daemon::task_board::evaluation` (#1145): pure data,
// needed there because `TaskBoardOrchestratorEvaluationOutcome`/`Record`
// embed them directly. `TaskBoardEvaluationSummary`/`TaskBoardEvaluationRecord`
// stay here: the latter embeds the full `TaskBoardItem` domain entity.
pub use harness_protocol::daemon::task_board::evaluation::{
    EvaluationSignalFailure, TaskBoardEvaluationOutcome,
};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
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
    /// The durable work-item state the board evaluated. Present for every
    /// dispatched item; `task_status` above is present only for the ones a
    /// legacy Session task was translated from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_state: Option<TaskBoardWorkItemState>,
    #[serde(default)]
    pub updated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<TaskBoardItem>,
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

/// Translates one legacy Session task into the work-item state the board owns.
///
/// This is the whole compatibility bridge: a Session-linked item still learns
/// its progress from its Session task, but that reading is fed through the same
/// durable record every sessionless worker reports into, rather than projected
/// onto the item behind the record's back. Nothing here creates a Session task.
#[must_use]
pub fn work_item_state_from_session_task(task: &WorkItem) -> TaskBoardWorkItemState {
    match task.status {
        TaskStatus::Open => TaskBoardWorkItemState::Pending,
        TaskStatus::InProgress => TaskBoardWorkItemState::Running,
        TaskStatus::AwaitingReview => TaskBoardWorkItemState::AwaitingReview,
        TaskStatus::InReview if changes_were_requested(task) => {
            TaskBoardWorkItemState::ChangesRequested
        }
        TaskStatus::InReview => TaskBoardWorkItemState::InReview,
        TaskStatus::Done => TaskBoardWorkItemState::Done,
        TaskStatus::Blocked => TaskBoardWorkItemState::Blocked,
    }
}

/// The reason a translated Session task carries into the record: whatever
/// blocked it, or the review consensus that sent it back to the worker.
#[must_use]
pub fn work_item_reason_from_session_task(task: &WorkItem) -> Option<String> {
    if task.status == TaskStatus::Blocked {
        return Some(
            task.blocked_reason
                .clone()
                .unwrap_or_else(|| "session task blocked".to_string()),
        );
    }
    changes_were_requested(task)
        .then(|| {
            task.consensus
                .as_ref()
                .map(|consensus| consensus.summary.clone())
        })
        .flatten()
        .filter(|summary| !summary.is_empty())
}

fn changes_were_requested(task: &WorkItem) -> bool {
    task.consensus
        .as_ref()
        .is_some_and(|consensus| !matches!(consensus.verdict, ReviewVerdict::Approve))
}

/// The evaluation outcome one work-item state reports.
#[must_use]
pub fn outcome_for_work_item_state(state: TaskBoardWorkItemState) -> TaskBoardEvaluationOutcome {
    match state {
        TaskBoardWorkItemState::Pending => TaskBoardEvaluationOutcome::WorkerPending,
        TaskBoardWorkItemState::Running => TaskBoardEvaluationOutcome::WorkerRunning,
        TaskBoardWorkItemState::AwaitingReview => TaskBoardEvaluationOutcome::ReviewPending,
        TaskBoardWorkItemState::InReview => TaskBoardEvaluationOutcome::ReviewRunning,
        TaskBoardWorkItemState::ChangesRequested => {
            TaskBoardEvaluationOutcome::ReviewChangesRequested
        }
        TaskBoardWorkItemState::Blocked => TaskBoardEvaluationOutcome::Blocked,
        TaskBoardWorkItemState::Done => TaskBoardEvaluationOutcome::Completed,
    }
}

/// Builds the evaluation record for one item straight from its durable
/// progress, for an item that has no Session task to read.
#[must_use]
pub fn record_from_work_item_progress(
    item: &TaskBoardItem,
    progress: &TaskBoardWorkItemProgress,
) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord {
        board_item_id: item.id.clone(),
        session_id: item.session_id.clone(),
        work_item_id: item.work_item_id.clone(),
        outcome: outcome_for_work_item_state(progress.state),
        task_status: None,
        board_status: Some(progress.state.board_status()),
        workflow_status: Some(progress.state.workflow_status()),
        work_item_state: Some(progress.state),
        updated: false,
        reason: progress.blocked_reason.clone(),
        item: None,
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
        work_item_state: None,
        updated: false,
        reason: Some("board item is not linked to a session task".to_string()),
        item: None,
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
        work_item_state: None,
        updated: false,
        reason: Some(reason),
        item: None,
    }
}

#[cfg(test)]
mod tests {
    use harness_session::types::{ReviewConsensus, TaskQueuePolicy, TaskSeverity, TaskSource};

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
            queue_policy: TaskQueuePolicy::default(),
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
    fn every_session_task_status_translates_to_a_work_item_state() {
        let cases = [
            (TaskStatus::Open, TaskBoardWorkItemState::Pending),
            (TaskStatus::InProgress, TaskBoardWorkItemState::Running),
            (
                TaskStatus::AwaitingReview,
                TaskBoardWorkItemState::AwaitingReview,
            ),
            (TaskStatus::InReview, TaskBoardWorkItemState::InReview),
            (TaskStatus::Done, TaskBoardWorkItemState::Done),
            (TaskStatus::Blocked, TaskBoardWorkItemState::Blocked),
        ];

        for (status, expected) in cases {
            assert_eq!(
                work_item_state_from_session_task(&task(status)),
                expected,
                "{status:?}"
            );
        }
    }

    #[test]
    fn a_review_asking_for_changes_returns_work_to_the_worker() {
        let mut task = task(TaskStatus::InReview);
        task.consensus = Some(ReviewConsensus {
            verdict: ReviewVerdict::RequestChanges,
            summary: "Needs one fix".to_string(),
            points: Vec::new(),
            closed_at: "2026-05-14T00:01:00Z".to_string(),
            reviewer_agent_ids: vec!["reviewer-1".to_string()],
        });

        assert_eq!(
            work_item_state_from_session_task(&task),
            TaskBoardWorkItemState::ChangesRequested
        );
        assert_eq!(
            work_item_reason_from_session_task(&task).as_deref(),
            Some("Needs one fix")
        );
    }

    #[test]
    fn an_approving_review_leaves_the_work_item_in_review() {
        let mut task = task(TaskStatus::InReview);
        task.consensus = Some(ReviewConsensus {
            verdict: ReviewVerdict::Approve,
            summary: "Looks good".to_string(),
            points: Vec::new(),
            closed_at: "2026-05-14T00:01:00Z".to_string(),
            reviewer_agent_ids: vec!["reviewer-1".to_string()],
        });

        assert_eq!(
            work_item_state_from_session_task(&task),
            TaskBoardWorkItemState::InReview
        );
        assert!(work_item_reason_from_session_task(&task).is_none());
    }

    #[test]
    fn a_blocked_task_carries_its_reason_across() {
        let mut task = task(TaskStatus::Blocked);
        task.blocked_reason = Some("needs a human decision".to_string());

        assert_eq!(
            work_item_reason_from_session_task(&task).as_deref(),
            Some("needs a human decision")
        );
    }

    #[test]
    fn a_blocked_task_without_a_reason_still_reports_one() {
        assert_eq!(
            work_item_reason_from_session_task(&task(TaskStatus::Blocked)).as_deref(),
            Some("session task blocked")
        );
    }

    #[test]
    fn every_work_item_state_maps_to_an_evaluation_outcome() {
        let cases = [
            (
                TaskBoardWorkItemState::Pending,
                TaskBoardEvaluationOutcome::WorkerPending,
            ),
            (
                TaskBoardWorkItemState::Running,
                TaskBoardEvaluationOutcome::WorkerRunning,
            ),
            (
                TaskBoardWorkItemState::AwaitingReview,
                TaskBoardEvaluationOutcome::ReviewPending,
            ),
            (
                TaskBoardWorkItemState::InReview,
                TaskBoardEvaluationOutcome::ReviewRunning,
            ),
            (
                TaskBoardWorkItemState::ChangesRequested,
                TaskBoardEvaluationOutcome::ReviewChangesRequested,
            ),
            (
                TaskBoardWorkItemState::Blocked,
                TaskBoardEvaluationOutcome::Blocked,
            ),
            (
                TaskBoardWorkItemState::Done,
                TaskBoardEvaluationOutcome::Completed,
            ),
        ];

        for (state, expected) in cases {
            assert_eq!(outcome_for_work_item_state(state), expected, "{state:?}");
        }
    }

    #[test]
    fn a_record_built_from_progress_reports_the_durable_state() {
        let item = item();
        let mut progress = TaskBoardWorkItemProgress::new(
            item.id.clone(),
            "task-board-1".to_string(),
            Some("workflow-1".to_string()),
            "2026-05-14T00:00:00Z".to_string(),
        );
        progress.state = TaskBoardWorkItemState::Blocked;
        progress.blocked_reason = Some("worktree unchanged".to_string());

        let record = record_from_work_item_progress(&item, &progress);

        assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Blocked);
        assert_eq!(record.board_status, Some(TaskBoardStatus::Failed));
        assert_eq!(
            record.workflow_status,
            Some(TaskBoardWorkflowStatus::Failed)
        );
        assert_eq!(
            record.work_item_state,
            Some(TaskBoardWorkItemState::Blocked)
        );
        assert_eq!(record.task_status, None);
        assert_eq!(record.reason.as_deref(), Some("worktree unchanged"));
    }
}
