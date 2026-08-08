//! Durable worker progress for one dispatched task-board work item.
//!
//! The board used to learn what a worker was doing by reading a Session task
//! and mirroring it. This module owns that state directly instead: one record
//! per work item, an append-only checkpoint log, and a pure transition that
//! decides whether an incoming report is applied or refused.

use serde::{Deserialize, Serialize};

use super::types::{TaskBoardStatus, TaskBoardWorkflowState, TaskBoardWorkflowStatus};

/// Longest checkpoint summary the board keeps. A worker that reports a whole
/// transcript would otherwise grow the row without bound.
pub const TASK_BOARD_WORK_ITEM_SUMMARY_LIMIT: usize = 2_000;

/// Where a dispatched work item stands, owned by the board rather than by a
/// Session task.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkItemState {
    /// Dispatched and bound to an execution, but the worker has not reported.
    #[default]
    Pending,
    Running,
    /// The worker handed the work off and is waiting for a reviewer to claim it.
    AwaitingReview,
    InReview,
    /// A reviewer asked for changes and the worker owns the work again.
    ChangesRequested,
    Blocked,
    Done,
}

impl TaskBoardWorkItemState {
    /// Whether the work item has settled. A settled work item never moves
    /// again: a re-dispatch mints a new work item rather than reopening this
    /// one, so a late or duplicated report has nothing legitimate to change.
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Blocked | Self::Done)
    }

    /// The lane the board shows while the work item is in this state.
    #[must_use]
    pub const fn board_status(self) -> TaskBoardStatus {
        match self {
            Self::Pending | Self::Running => TaskBoardStatus::InProgress,
            Self::AwaitingReview => TaskBoardStatus::ToReview,
            Self::InReview | Self::ChangesRequested => TaskBoardStatus::InReview,
            Self::Blocked => TaskBoardStatus::Failed,
            Self::Done => TaskBoardStatus::Done,
        }
    }

    /// The workflow status the board shows alongside the lane.
    #[must_use]
    pub const fn workflow_status(self) -> TaskBoardWorkflowStatus {
        match self {
            Self::Pending
            | Self::Running
            | Self::AwaitingReview
            | Self::InReview
            | Self::ChangesRequested => TaskBoardWorkflowStatus::Running,
            Self::Blocked => TaskBoardWorkflowStatus::Failed,
            Self::Done => TaskBoardWorkflowStatus::Completed,
        }
    }

    /// The workflow step id the board shows for this state.
    ///
    /// `Pending` has two: a dispatch held for delivery keeps its own step so
    /// the board does not claim a worker is pending when nothing was handed to
    /// one yet.
    #[must_use]
    pub const fn workflow_step(self, held_for_delivery: bool) -> &'static str {
        match self {
            Self::Pending if held_for_delivery => "awaiting_delivery",
            Self::Pending => "worker_pending",
            Self::Running => "worker",
            Self::AwaitingReview => "review_pending",
            Self::InReview => "review",
            Self::ChangesRequested => "review_changes_requested",
            Self::Blocked => "blocked",
            Self::Done => "completed",
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::AwaitingReview => "awaiting_review",
            Self::InReview => "in_review",
            Self::ChangesRequested => "changes_requested",
            Self::Blocked => "blocked",
            Self::Done => "done",
        }
    }

    /// Parses the persisted spelling.
    #[must_use]
    pub fn from_str_opt(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "running" => Some(Self::Running),
            "awaiting_review" => Some(Self::AwaitingReview),
            "in_review" => Some(Self::InReview),
            "changes_requested" => Some(Self::ChangesRequested),
            "blocked" => Some(Self::Blocked),
            "done" => Some(Self::Done),
            _ => None,
        }
    }
}

/// One append-only checkpoint a worker recorded against its work item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemCheckpoint {
    pub checkpoint_id: String,
    /// Position in this work item's checkpoint log, starting at 1.
    pub sequence: u64,
    pub actor: String,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(maximum = 100)]
    pub progress_percent: Option<u8>,
    /// The worker run that produced this checkpoint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempt_id: Option<String>,
    pub recorded_at: String,
}

/// The durable progress record for one dispatched work item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemProgress {
    pub board_item_id: String,
    pub work_item_id: String,
    /// The execution that owns this work item, when the item carries one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_id: Option<String>,
    pub state: TaskBoardWorkItemState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(maximum = 100)]
    pub progress_percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    /// The worker run that last moved this work item. Preserved across a review
    /// handoff so a reviewer can tell which attempt produced the work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempt_id: Option<String>,
    /// The board item revision the last accepted report was stamped at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_revision: Option<u64>,
    /// Monotonic report counter. A report that does not advance it is refused.
    #[serde(default)]
    pub report_sequence: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checkpoints: Vec<TaskBoardWorkItemCheckpoint>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

impl TaskBoardWorkItemProgress {
    /// The record a freshly dispatched work item starts from.
    #[must_use]
    pub fn new(
        board_item_id: String,
        work_item_id: String,
        execution_id: Option<String>,
        now: String,
    ) -> Self {
        Self {
            board_item_id,
            work_item_id,
            execution_id,
            state: TaskBoardWorkItemState::Pending,
            progress_percent: None,
            summary: None,
            blocked_reason: None,
            attempt_id: None,
            item_revision: None,
            report_sequence: 0,
            checkpoints: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
            completed_at: None,
        }
    }

    /// The checkpoint the board shows as "latest", if the worker recorded any.
    #[must_use]
    pub fn latest_checkpoint(&self) -> Option<&TaskBoardWorkItemCheckpoint> {
        self.checkpoints.last()
    }

    /// Projects this record onto the board item's workflow state, preserving
    /// the fields the workflow owns (execution binding, attempts, traces).
    #[must_use]
    pub fn project_workflow(&self, current: &TaskBoardWorkflowState) -> TaskBoardWorkflowState {
        let held_for_delivery = current.current_step_id.as_deref() == Some("awaiting_delivery");
        let mut workflow = current.clone();
        workflow.status = self.state.workflow_status();
        workflow.current_step_id = Some(self.state.workflow_step(held_for_delivery).to_owned());
        workflow.last_error.clone_from(&self.blocked_reason);
        workflow
    }
}

/// One worker report, already resolved by the caller: the attempt identity and
/// the item revision are stamped by the daemon rather than trusted from the
/// worker, so a review handoff always carries the revision it really ran at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardWorkItemReport {
    pub actor: String,
    /// `None` records a checkpoint without moving the work item.
    pub state: Option<TaskBoardWorkItemState>,
    pub summary: Option<String>,
    pub progress_percent: Option<u8>,
    pub blocked_reason: Option<String>,
    pub attempt_id: Option<String>,
    pub item_revision: Option<u64>,
    /// Client-supplied ordering fence. `None` takes the next sequence.
    pub sequence: Option<u64>,
    pub checkpoint_id: String,
    pub recorded_at: String,
}

/// Why a report left the record untouched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkItemReportRejection {
    /// The work item already settled; nothing may move it again.
    Terminal,
    /// The report's ordering fence is not newer than the recorded one.
    StaleSequence,
}

impl TaskBoardWorkItemReportRejection {
    #[must_use]
    pub const fn message(self) -> &'static str {
        match self {
            Self::Terminal => "work item already settled; report ignored",
            Self::StaleSequence => "report is older than the recorded progress; report ignored",
        }
    }
}

/// What a report did to the record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardWorkItemReportOutcome {
    Applied(TaskBoardWorkItemProgress),
    Ignored {
        current: TaskBoardWorkItemProgress,
        rejection: TaskBoardWorkItemReportRejection,
    },
}

impl TaskBoardWorkItemReportOutcome {
    /// The record as it stands after the report, applied or not.
    #[must_use]
    pub const fn progress(&self) -> &TaskBoardWorkItemProgress {
        match self {
            Self::Applied(progress)
            | Self::Ignored {
                current: progress, ..
            } => progress,
        }
    }

    #[must_use]
    pub const fn applied(&self) -> bool {
        matches!(self, Self::Applied(_))
    }

    #[must_use]
    pub const fn rejection(&self) -> Option<TaskBoardWorkItemReportRejection> {
        match self {
            Self::Applied(_) => None,
            Self::Ignored { rejection, .. } => Some(*rejection),
        }
    }
}

/// Applies one worker report to the durable record.
///
/// Two rules keep repeated and out-of-order reports honest, and they are the
/// only ones: a settled work item is frozen, and a report must carry an
/// ordering fence newer than the recorded one. Everything else - including a
/// reviewer sending the work back to the worker - is a legitimate move.
#[must_use]
pub fn apply_work_item_report(
    current: &TaskBoardWorkItemProgress,
    report: &TaskBoardWorkItemReport,
) -> TaskBoardWorkItemReportOutcome {
    if current.state.is_terminal() {
        return TaskBoardWorkItemReportOutcome::Ignored {
            current: current.clone(),
            rejection: TaskBoardWorkItemReportRejection::Terminal,
        };
    }
    let sequence = report.sequence.unwrap_or(current.report_sequence + 1);
    if sequence <= current.report_sequence {
        return TaskBoardWorkItemReportOutcome::Ignored {
            current: current.clone(),
            rejection: TaskBoardWorkItemReportRejection::StaleSequence,
        };
    }
    let mut updated = current.clone();
    updated.report_sequence = sequence;
    updated.updated_at.clone_from(&report.recorded_at);
    overwrite_reported_fields(&mut updated, report);
    updated.blocked_reason = blocked_reason_for(&updated, report);
    push_checkpoint(&mut updated, report);
    if updated.state.is_terminal() {
        updated.completed_at = Some(report.recorded_at.clone());
    }
    TaskBoardWorkItemReportOutcome::Applied(updated)
}

/// Copies across only what the report actually names. A field the report omits
/// keeps its recorded value, so a plain checkpoint cannot erase the attempt
/// identity or revision an earlier review handoff established.
fn overwrite_reported_fields(
    updated: &mut TaskBoardWorkItemProgress,
    report: &TaskBoardWorkItemReport,
) {
    if let Some(state) = report.state {
        updated.state = state;
    }
    if let Some(percent) = report.progress_percent {
        updated.progress_percent = Some(percent.min(100));
    }
    if let Some(summary) = report.summary.as_deref() {
        updated.summary = Some(truncate_summary(summary));
    }
    if report.attempt_id.is_some() {
        updated.attempt_id.clone_from(&report.attempt_id);
    }
    if report.item_revision.is_some() {
        updated.item_revision = report.item_revision;
    }
}

/// A blocked work item keeps a reason; leaving the blocked state drops the one
/// that no longer applies rather than leaving a stale error on the board.
fn blocked_reason_for(
    updated: &TaskBoardWorkItemProgress,
    report: &TaskBoardWorkItemReport,
) -> Option<String> {
    if updated.state != TaskBoardWorkItemState::Blocked {
        return None;
    }
    report
        .blocked_reason
        .as_deref()
        .or(report.summary.as_deref())
        .map(truncate_summary)
        .or_else(|| updated.blocked_reason.clone())
}

fn push_checkpoint(updated: &mut TaskBoardWorkItemProgress, report: &TaskBoardWorkItemReport) {
    let Some(summary) = report
        .summary
        .as_deref()
        .map(str::trim)
        .filter(|summary| !summary.is_empty())
    else {
        return;
    };
    let sequence = updated
        .checkpoints
        .last()
        .map_or(1, |checkpoint| checkpoint.sequence + 1);
    updated.checkpoints.push(TaskBoardWorkItemCheckpoint {
        checkpoint_id: report.checkpoint_id.clone(),
        sequence,
        actor: report.actor.clone(),
        summary: truncate_summary(summary),
        progress_percent: report.progress_percent.map(|percent| percent.min(100)),
        attempt_id: updated.attempt_id.clone(),
        recorded_at: report.recorded_at.clone(),
    });
}

fn truncate_summary(value: &str) -> String {
    let trimmed = value.trim();
    let mut characters = trimmed.chars();
    let truncated: String = characters
        .by_ref()
        .take(TASK_BOARD_WORK_ITEM_SUMMARY_LIMIT)
        .collect();
    if characters.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}

#[cfg(test)]
#[path = "work_item_progress_tests.rs"]
mod tests;
