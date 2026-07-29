//! `PlanApprovalBlockReason`, relocated here from `harness-task-board::planning`.
//! Pure data with no fields and no inherent methods; `PlanApprovalGate`,
//! `PlanningTransition`, and the approval-workflow functions that build them
//! stay in `harness-task-board`, since they reach the full `TaskBoardItem`
//! domain entity this move has no need for. `harness-task-board` re-exports
//! this name at the same path.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum PlanApprovalBlockReason {
    Deleted,
    MissingSummary,
    MissingApprover,
    MissingApprovalTime,
}
