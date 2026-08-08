use crate::daemon::protocol::{TaskBoardDispatchRequest, TaskBoardEvaluateRequest};
use crate::task_board::orchestrator::TaskBoardOrchestratorPreparedRun;
use crate::task_board::{
    DispatchExecutionSummary, TaskBoardEvaluationSummary, TaskBoardItem,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorTickPhase, TaskBoardWorkflowKind,
};
use harness_kernel::errors::CliError;

use super::TaskBoardAutomationRunSession;
use super::task_board::dispatch_task_board_for_orchestrator_async;
use super::task_board_evaluation::evaluate_task_board_async;
use super::task_board_github::run_task_board_github_automation_async;
use super::task_board_orchestrator_db::record_tick;
use super::task_board_orchestrator_step_mode::scoped_dispatch_request;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

/// A dry run has no request to dispatch, so it reports an empty summary rather
/// than skipping the stage: the caller still records stage 3 as run.
pub(super) async fn run_dispatch_phase(
    db: &AsyncDaemonDbHandle,
    settings: &TaskBoardOrchestratorSettings,
    prepared: &TaskBoardOrchestratorPreparedRun,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<(Option<TaskBoardDispatchRequest>, DispatchExecutionSummary), CliError> {
    let request = scoped_dispatch_request(db, settings, &prepared.input).await?;
    let dispatch = match request.as_ref() {
        Some(request) => {
            dispatch_task_board_for_orchestrator_async(
                request,
                db,
                &prepared.candidate_item_ids,
                settings,
                session,
            )
            .await?
        }
        None => DispatchExecutionSummary::dry_run(Vec::new()),
    };
    Ok((request, dispatch))
}

pub(super) async fn run_evaluation_phase(
    db: &AsyncDaemonDbHandle,
    prepared: &TaskBoardOrchestratorPreparedRun,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<TaskBoardEvaluationSummary, CliError> {
    ensure_active(session).await?;
    record_tick(
        db,
        &prepared.run_id,
        &prepared.started_at,
        prepared.input.dry_run,
        TaskBoardOrchestratorTickPhase::Evaluation,
    )
    .await?;
    let mut combined = TaskBoardEvaluationSummary::default();
    for item_id in &prepared.candidate_item_ids {
        ensure_active(session).await?;
        let summary = Box::pin(evaluate_task_board_async(
            &TaskBoardEvaluateRequest {
                item_id: Some(item_id.clone()),
                status: None,
                dry_run: prepared.input.dry_run,
            },
            db,
        ))
        .await?;
        merge_evaluation(&mut combined, summary);
    }
    Ok(combined)
}

/// Review workflows publish through their own route, so they are dropped here
/// rather than filtered upstream where the dispatch stage still needs them.
pub(super) async fn run_publish_phase(
    db: &AsyncDaemonDbHandle,
    settings: &TaskBoardOrchestratorSettings,
    prepared: &TaskBoardOrchestratorPreparedRun,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<(), CliError> {
    ensure_active(session).await?;
    let mut items = load_candidate_items(db, &prepared.candidate_item_ids, session).await?;
    items.retain(|item| {
        !(matches!(item.workflow_kind, TaskBoardWorkflowKind::Review)
            || item.workflow_kind.is_read_only_review())
    });
    run_task_board_github_automation_async(settings, &prepared.input, &items, db, session).await
}

fn merge_evaluation(
    combined: &mut TaskBoardEvaluationSummary,
    mut next: TaskBoardEvaluationSummary,
) {
    for record in next.records.drain(..) {
        combined.push(record);
    }
    combined.signal_failures.append(&mut next.signal_failures);
}

async fn load_candidate_items(
    db: &AsyncDaemonDbHandle,
    item_ids: &[String],
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let mut items = Vec::with_capacity(item_ids.len());
    for item_id in item_ids {
        ensure_active(session).await?;
        items.push(
            super::task_board_repository_scope::scoped_task_board_item_db(db, item_id).await?,
        );
    }
    Ok(items)
}

async fn ensure_active(session: Option<&TaskBoardAutomationRunSession>) -> Result<(), CliError> {
    if let Some(session) = session {
        session.ensure_active().await?;
    }
    Ok(())
}
