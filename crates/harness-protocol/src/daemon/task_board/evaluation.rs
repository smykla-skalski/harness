//! `TaskBoardEvaluationOutcome` and `EvaluationSignalFailure`, relocated here
//! from `harness-task-board::evaluation`. `TaskBoardEvaluationSummary`,
//! `TaskBoardEvaluationRecord`, `TaskBoardEvaluationDecision`, and the
//! `evaluate_task_board_item`/`*_record` builder functions stay in
//! `harness-task-board`: `TaskBoardEvaluationRecord` embeds the full
//! `TaskBoardItem` domain entity, which this move has no need for.
//! `harness-task-board` re-exports both names below at the same path.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct EvaluationSignalFailure {
    pub board_item_id: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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

// Existing coverage for these types stays in
// `harness-task-board::evaluation`'s own test module, exercised through the
// re-export below.
