//! `TaskBoardOrchestratorWorkflow` and `TaskBoardPhaseCapabilityProfile`,
//! reached forward out of `harness-task-board::automation::orchestrator_workflow`
//! and `harness-task-board::automation::workflow` respectively, the same way
//! `harness-task-board` itself already reaches `TaskBoardOrchestratorWorkflow`
//! forward out of `orchestrator::types` for its own `settings.rs`: both are
//! embedded by `TaskBoardOrchestratorSettings`/`TaskBoardRepositoryAutomationConfig`
//! (`orchestrator_workflow`) and `TaskBoardLocalExecutionHostConfig`
//! (`workflow`'s `TaskBoardPhaseCapabilityProfile`), but the rest of each
//! source file stays behind: `workflow.rs`'s other types carry real execution
//! state this move has no need for.

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardPhaseCapabilityProfile {
    PlanningReadOnly,
    ImplementationWrite,
    ReviewReadOnly,
    EvaluateReadOnly,
}
