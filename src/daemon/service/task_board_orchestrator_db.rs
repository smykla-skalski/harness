use std::collections::BTreeSet;

use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardEvaluateRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardSyncRequest,
};
use crate::errors::CliError;
use crate::task_board::github::GitHubAutomation;
use crate::task_board::orchestrator::TaskBoardOrchestratorPreparedRun;
use crate::task_board::{
    DispatchExecutionSummary, ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
    SpawnGateSwitches, TaskBoardAuditSummary, TaskBoardEvaluationSummary, TaskBoardItem,
    TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorRunStatus,
    TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorSettings, TaskBoardOrchestratorTickInfo,
    TaskBoardOrchestratorTickPhase, TaskBoardStatus, build_audit_summary_with_policy,
    build_sync_summary,
};
use crate::workspace::utc_now;

use super::TaskBoardAutomationRunSession;
use super::task_board::{dispatch_task_board_async, load_live_spawn_grants};
use super::task_board_db::{
    active_external_sync_config_db, sync_task_board_for_orchestrator_db,
    sync_task_board_for_orchestrator_with_context_db, task_board_host_local_db,
};
use super::task_board_evaluation::evaluate_task_board_async;
use super::task_board_github::run_task_board_github_automation_async;
use super::task_board_orchestrator_control::task_board_orchestrator_status_db;
use super::task_board_orchestrator_step_mode::scoped_dispatch_request;

pub(crate) async fn run_task_board_orchestrator_once_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    run_task_board_orchestrator_once_inner(db, request, None).await
}

pub(crate) async fn run_task_board_orchestrator_once_with_session_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
    session: &TaskBoardAutomationRunSession,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    run_task_board_orchestrator_once_inner(db, request, Some(session)).await
}

async fn run_task_board_orchestrator_once_inner(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    begin_stage(session, 1, "prepare").await?;
    let prepared = prepare_run(
        db,
        request,
        &settings,
        session.map(TaskBoardAutomationRunSession::run_id),
    )
    .await;
    let mut prepared = finish_stage(session, 1, "prepare", prepared).await?;
    let mut progress = (None, None);
    match execute_run(db, &settings, &mut prepared, &mut progress, session).await {
        Ok((dispatch, evaluation)) => complete_run(db, prepared, dispatch, evaluation).await,
        Err(error) => {
            record_failed_run(db, &prepared, progress, &error).await?;
            Err(error)
        }
    }
}

async fn prepare_run(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
    settings: &TaskBoardOrchestratorSettings,
    durable_run_id: Option<&str>,
) -> Result<TaskBoardOrchestratorPreparedRun, CliError> {
    let input = dispatch_input(request, settings);
    let run_id = durable_run_id.map_or_else(
        || format!("task-board-run-{}", Uuid::new_v4().simple()),
        ToOwned::to_owned,
    );
    let started_at = utc_now();
    record_tick(
        db,
        &run_id,
        &started_at,
        input.dry_run,
        TaskBoardOrchestratorTickPhase::Dispatch,
    )
    .await?;
    let items = items_for_input(db, &input).await?;
    let config = active_external_sync_config_db(db).await?;
    Ok(TaskBoardOrchestratorPreparedRun {
        run_id,
        started_at,
        input,
        sync: build_sync_summary(&items, &config),
        audit: audit_summary(db, &items).await?,
    })
}

async fn execute_run(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
    progress: &mut (
        Option<DispatchExecutionSummary>,
        Option<TaskBoardEvaluationSummary>,
    ),
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<(DispatchExecutionSummary, TaskBoardEvaluationSummary), CliError> {
    begin_stage(session, 2, "provider_sync").await?;
    let sync = sync_github_tasks(db, settings, prepared, session).await;
    finish_stage(session, 2, "provider_sync", sync).await?;

    begin_stage(session, 3, "dispatch").await?;
    let dispatch = async {
        let request = scoped_dispatch_request(db, settings, &prepared.input).await?;
        let dispatch = match request.as_ref() {
            Some(request) => dispatch_task_board_async(request, db).await?,
            None => DispatchExecutionSummary::dry_run(Vec::new()),
        };
        Ok((request, dispatch))
    }
    .await;
    let (request, dispatch) = finish_stage(session, 3, "dispatch", dispatch).await?;
    progress.0 = Some(dispatch.clone());

    begin_stage(session, 4, "evaluation").await?;
    let evaluation = async {
        record_tick(
            db,
            &prepared.run_id,
            &prepared.started_at,
            prepared.input.dry_run,
            TaskBoardOrchestratorTickPhase::Evaluation,
        )
        .await?;
        evaluate_task_board_async(
            &TaskBoardEvaluateRequest {
                item_id: request
                    .as_ref()
                    .and_then(|request| request.item_id.clone())
                    .or_else(|| prepared.input.item_id.clone()),
                status: None,
                dry_run: prepared.input.dry_run,
            },
            db,
        )
        .await
    }
    .await;
    let evaluation = finish_stage(session, 4, "evaluation", evaluation).await?;
    progress.1 = Some(evaluation.clone());

    begin_stage(session, 5, "publish").await?;
    let publish = async {
        let items = items_for_input(db, &prepared.input).await?;
        run_task_board_github_automation_async(settings, &prepared.input, &items, db).await
    }
    .await;
    finish_stage(session, 5, "publish", publish).await?;
    Ok((dispatch, evaluation))
}

async fn finish_stage<T>(
    session: Option<&TaskBoardAutomationRunSession>,
    sequence: u64,
    stage: &str,
    result: Result<T, CliError>,
) -> Result<T, CliError> {
    match result {
        Ok(value) => {
            complete_stage(session, sequence, stage).await?;
            Ok(value)
        }
        Err(error) => {
            fail_stage(session, sequence, stage, &error).await?;
            Err(error)
        }
    }
}

async fn begin_stage(
    session: Option<&TaskBoardAutomationRunSession>,
    sequence: u64,
    stage: &str,
) -> Result<(), CliError> {
    if let Some(session) = session {
        session.begin_stage(sequence, stage, None, None).await?;
    }
    Ok(())
}

async fn complete_stage(
    session: Option<&TaskBoardAutomationRunSession>,
    sequence: u64,
    stage: &str,
) -> Result<(), CliError> {
    if let Some(session) = session {
        session.complete_stage(sequence, stage, None, None).await?;
    }
    Ok(())
}

async fn fail_stage(
    session: Option<&TaskBoardAutomationRunSession>,
    sequence: u64,
    stage: &str,
    error: &CliError,
) -> Result<(), CliError> {
    if let Some(session) = session {
        session.fail_stage(sequence, stage, error).await?;
    }
    Ok(())
}

async fn sync_github_tasks(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
    session: Option<&TaskBoardAutomationRunSession>,
) -> Result<(), CliError> {
    if prepared.input.item_id.is_some()
        || prepared
            .input
            .status
            .is_some_and(|status| status != TaskBoardStatus::Todo)
        || (!settings
            .github_project
            .enabled_automations
            .enables(GitHubAutomation::SyncTaskBoard)
            && settings.github_inbox.repositories.is_empty())
    {
        return Ok(());
    }
    let config = active_external_sync_config_db(db).await?;
    if config.token_for(ExternalProvider::GitHub).is_none()
        || (config.github_repository().is_none() && config.github_inbox_repositories().is_empty())
    {
        return Ok(());
    }
    let request = TaskBoardSyncRequest {
        status: prepared.input.status,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: prepared.input.dry_run,
    };
    prepared.sync = if let Some(session) = session {
        let context = session.sync_context();
        sync_task_board_for_orchestrator_with_context_db(db, &request, &context).await?
    } else {
        sync_task_board_for_orchestrator_db(db, &request).await?
    };
    prepared.audit = audit_summary(db, &items_for_input(db, &prepared.input).await?).await?;
    Ok(())
}

async fn audit_summary(
    db: &AsyncDaemonDb,
    items: &[TaskBoardItem],
) -> Result<TaskBoardAuditSummary, CliError> {
    let workspace = db.load_policy_workspace().await?;
    let policy = workspace
        .as_ref()
        .and_then(|workspace| workspace.active_live_canvas())
        .map(|(canvas, document)| (canvas.id.as_str(), document));
    let switches = workspace
        .as_ref()
        .map(SpawnGateSwitches::from_workspace)
        .unwrap_or_default();
    let grants = load_live_spawn_grants(db, policy, items, &[]).await?;
    let evaluated_at = utc_now();
    Ok(build_audit_summary_with_policy(
        items,
        policy,
        &evaluated_at,
        switches,
        &grants,
    ))
}

fn dispatch_input(
    request: &TaskBoardOrchestratorRunOnceRequest,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardOrchestratorDispatchInput {
    TaskBoardOrchestratorDispatchInput {
        item_id: request.item_id.clone(),
        status: request
            .status
            .or(settings.dispatch_status_filter)
            .map(TaskBoardStatus::canonical_persisted_status),
        dry_run: request.dry_run.unwrap_or(settings.dry_run_default),
        project_dir: request
            .project_dir
            .clone()
            .or_else(|| settings.project_dir.clone())
            .or_else(|| {
                (!settings.github_project.checkout_path.as_os_str().is_empty()).then(|| {
                    settings
                        .github_project
                        .checkout_path
                        .to_string_lossy()
                        .into_owned()
                })
            }),
        actor: request.actor.clone(),
    }
}

async fn items_for_input(
    db: &AsyncDaemonDb,
    input: &TaskBoardOrchestratorDispatchInput,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let items = if let Some(item_id) = input.item_id.as_deref() {
        vec![db.task_board_item(item_id).await?]
    } else {
        db.list_task_board_items(input.status).await?
    };
    let machine = task_board_host_local_db(db).await.ok();
    Ok(items
        .into_iter()
        .filter(|item| {
            machine
                .as_ref()
                .is_none_or(|machine| machine.accepts_any(&item.target_project_types))
        })
        .collect())
}

async fn record_tick(
    db: &AsyncDaemonDb,
    run_id: &str,
    started_at: &str,
    dry_run: bool,
    phase: TaskBoardOrchestratorTickPhase,
) -> Result<(), CliError> {
    let mut state = db.task_board_orchestrator_state().await?;
    state.current_tick = Some(TaskBoardOrchestratorTickInfo {
        run_id: run_id.to_string(),
        phase,
        started_at: started_at.to_string(),
        completed_at: None,
        dry_run,
    });
    db.replace_task_board_orchestrator_state(&state).await?;
    Ok(())
}

async fn complete_run(
    db: &AsyncDaemonDb,
    prepared: TaskBoardOrchestratorPreparedRun,
    dispatch: DispatchExecutionSummary,
    evaluation: TaskBoardEvaluationSummary,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let summary = run_summary(
        prepared,
        Some(dispatch),
        Some(evaluation),
        None,
        TaskBoardOrchestratorRunStatus::Completed,
    );
    save_run_summary(db, summary, TaskBoardOrchestratorTickPhase::Completed).await?;
    task_board_orchestrator_status_db(db).await
}

async fn record_failed_run(
    db: &AsyncDaemonDb,
    prepared: &TaskBoardOrchestratorPreparedRun,
    progress: (
        Option<DispatchExecutionSummary>,
        Option<TaskBoardEvaluationSummary>,
    ),
    error: &CliError,
) -> Result<(), CliError> {
    let summary = run_summary(
        prepared.clone(),
        progress.0,
        progress.1,
        Some(error.to_string()),
        TaskBoardOrchestratorRunStatus::Failed,
    );
    save_run_summary(db, summary, TaskBoardOrchestratorTickPhase::Failed).await
}

fn run_summary(
    prepared: TaskBoardOrchestratorPreparedRun,
    dispatch: Option<DispatchExecutionSummary>,
    evaluation: Option<TaskBoardEvaluationSummary>,
    error: Option<String>,
    status: TaskBoardOrchestratorRunStatus,
) -> TaskBoardOrchestratorRunSummary {
    let policy_trace_ids = policy_trace_ids(dispatch.as_ref(), evaluation.as_ref());
    TaskBoardOrchestratorRunSummary {
        run_id: prepared.run_id,
        started_at: prepared.started_at,
        completed_at: utc_now(),
        status,
        dry_run: prepared.input.dry_run,
        sync: prepared.sync,
        audit: prepared.audit,
        dispatch,
        evaluation,
        error,
        policy_trace_ids,
    }
}

fn policy_trace_ids(
    dispatch: Option<&DispatchExecutionSummary>,
    evaluation: Option<&TaskBoardEvaluationSummary>,
) -> Vec<String> {
    let mut trace_ids = BTreeSet::new();
    if let Some(dispatch) = dispatch {
        for applied in &dispatch.applied {
            trace_ids.extend(applied.item.workflow.policy_trace_ids.iter().cloned());
        }
    }
    if let Some(evaluation) = evaluation {
        for record in &evaluation.records {
            if let Some(item) = &record.item {
                trace_ids.extend(item.workflow.policy_trace_ids.iter().cloned());
            }
        }
    }
    trace_ids.into_iter().collect()
}

async fn save_run_summary(
    db: &AsyncDaemonDb,
    summary: TaskBoardOrchestratorRunSummary,
    phase: TaskBoardOrchestratorTickPhase,
) -> Result<(), CliError> {
    let mut state = db.task_board_orchestrator_state().await?;
    state.current_tick = Some(TaskBoardOrchestratorTickInfo {
        run_id: summary.run_id.clone(),
        phase,
        started_at: summary.started_at.clone(),
        completed_at: Some(summary.completed_at.clone()),
        dry_run: summary.dry_run,
    });
    state.last_run = Some(summary);
    db.replace_task_board_orchestrator_state(&state).await?;
    Ok(())
}
