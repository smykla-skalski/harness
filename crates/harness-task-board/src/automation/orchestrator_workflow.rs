//! `TaskBoardOrchestratorWorkflow`, reached forward out of
//! `task_board::orchestrator::types` because `settings.rs` and
//! `reviewer_resolution.rs` need it. The rest of that file stays in the root
//! crate: its other types also depend on `dispatch`/`evaluation`/`summary`,
//! none of which have moved yet, so only this one enum comes along.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardOrchestratorWorkflow {
    DefaultTask,
    PrFix,
    PrReview,
    Review,
}
