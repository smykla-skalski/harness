use std::collections::BTreeSet;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardDispatchRequest, TaskBoardDispatchResponse};
use crate::task_board::{
    DispatchExecutionSummary, DispatchFailure, DispatchPlan, TaskBoardOrchestratorSettings,
    TaskBoardWorkflowStatus,
};
use harness_kernel::errors::CliError;

use super::super::TaskBoardAutomationRunSession;
use super::dispatch::{
    apply_dispatch_plan_async, build_dispatch_plans_for_request_async, reject_explicit_kind_block,
};
use crate::daemon::db::task_board::prelude::*;

pub(crate) async fn dispatch_task_board_for_orchestrator_async(
    request: &TaskBoardDispatchRequest,
    db: &AsyncDaemonDb,
    candidate_item_ids: &[String],
    settings: &TaskBoardOrchestratorSettings,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let candidates = candidate_item_ids.iter().collect::<BTreeSet<_>>();
    let mut plans = build_dispatch_plans_for_request_async(db, request).await?;
    plans.retain(|plan| candidates.contains(&plan.board_item_id));
    if request.dry_run {
        return Ok(DispatchExecutionSummary::dry_run(plans));
    }
    reject_explicit_kind_block(request, &plans)?;
    let budget = request_dispatch_budget(request, db, settings).await?;
    execute_plans(request, db, plans, budget, session).await
}

/// The board-wide concurrency cap paces unscoped background passes. A request
/// that names its item is the caller's own choice - step mode reaches here that
/// way too, since it picks one item up front - so counting workflows the run
/// never targeted would starve the single item it did name.
async fn request_dispatch_budget(
    request: &TaskBoardDispatchRequest,
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
) -> Result<usize, CliError> {
    if request.item_id.is_some() {
        return Ok(per_run_dispatch_budget(settings));
    }
    let active_items =
        super::super::task_board_repository_scope::scoped_task_board_items_db(db, None).await?;
    let active_workflows = active_workflow_count(&active_items);
    Ok(dispatch_budget(settings, active_workflows))
}

async fn execute_plans(
    request: &TaskBoardDispatchRequest,
    db: &AsyncDaemonDb,
    plans: Vec<DispatchPlan>,
    budget: usize,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    let hold_worker = db.task_board_orchestrator_settings().await?.step_mode;
    if let Some(session) = session {
        session.ensure_active().await?;
    }
    for plan in plans.iter().filter(|plan| plan.is_ready()).take(budget) {
        if let Some(session) = session {
            session.ensure_active().await?;
        }
        match Box::pin(apply_dispatch_plan_async(request, db, plan, hold_worker)).await {
            Ok(task) => applied.push(task),
            Err((kind, error)) => failures.push(DispatchFailure {
                board_item_id: plan.board_item_id.clone(),
                kind,
                message: error.to_string(),
            }),
        }
    }
    Ok(DispatchExecutionSummary {
        plans,
        applied,
        failures,
    })
}

fn active_workflow_count(items: &[crate::task_board::TaskBoardItem]) -> usize {
    items
        .iter()
        .filter(|item| {
            matches!(
                item.workflow.status,
                TaskBoardWorkflowStatus::Admitting
                    | TaskBoardWorkflowStatus::Running
                    | TaskBoardWorkflowStatus::Paused
            )
        })
        .count()
}

fn per_run_dispatch_budget(settings: &TaskBoardOrchestratorSettings) -> usize {
    usize::try_from(settings.scheduling.max_dispatches_per_run).unwrap_or(usize::MAX)
}

fn dispatch_budget(settings: &TaskBoardOrchestratorSettings, active_workflows: usize) -> usize {
    let active_workflows = u32::try_from(active_workflows).unwrap_or(u32::MAX);
    let concurrent_slots = settings
        .scheduling
        .max_concurrent_workflows
        .saturating_sub(active_workflows);
    per_run_dispatch_budget(settings).min(usize::try_from(concurrent_slots).unwrap_or(usize::MAX))
}

#[cfg(test)]
mod tests {
    use super::{dispatch_budget, per_run_dispatch_budget};
    use crate::task_board::TaskBoardOrchestratorSettings;

    #[test]
    fn dispatch_budget_enforces_per_run_and_concurrent_limits() {
        let mut settings = TaskBoardOrchestratorSettings::default();
        settings.scheduling.max_dispatches_per_run = 3;
        settings.scheduling.max_concurrent_workflows = 2;

        assert_eq!(dispatch_budget(&settings, 0), 2);
        assert_eq!(dispatch_budget(&settings, 1), 1);
        assert_eq!(dispatch_budget(&settings, 2), 0);
    }

    /// A named item must still dispatch with the board's default single
    /// concurrency slot already taken by an unrelated workflow.
    #[test]
    fn explicit_dispatch_ignores_the_board_wide_concurrency_cap() {
        let settings = TaskBoardOrchestratorSettings::default();
        assert_eq!(dispatch_budget(&settings, 1), 0);
        assert_eq!(per_run_dispatch_budget(&settings), 1);
    }

    #[test]
    fn explicit_dispatch_still_honors_the_per_run_cap() {
        let mut settings = TaskBoardOrchestratorSettings::default();
        settings.scheduling.max_dispatches_per_run = 2;
        settings.scheduling.max_concurrent_workflows = 0;

        assert_eq!(per_run_dispatch_budget(&settings), 2);
    }
}
