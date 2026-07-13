use std::collections::BTreeSet;

use uuid::Uuid;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardDispatchRequest, TaskBoardEvaluateRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse,
    TaskBoardSyncRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::GitHubAutomation;
use crate::task_board::orchestrator::TaskBoardOrchestratorPreparedRun;
use crate::task_board::{
    DispatchExecutionSummary, ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
    SpawnGateSwitches, TaskBoardAuditSummary, TaskBoardEvaluationSummary,
    TaskBoardGitHubInboxConfig, TaskBoardItem, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunStatus, TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorState, TaskBoardOrchestratorTickInfo, TaskBoardOrchestratorTickPhase,
    TaskBoardStatus, TaskBoardTodoistInboxConfig, TaskBoardWorkflowExecutionCount,
    TaskBoardWorkflowStatus, build_audit_summary_with_policy, build_sync_summary,
    normalize_repository_slug,
};
use crate::workspace::utc_now;

use super::task_board::dispatch_task_board_async;
use super::task_board_db::{
    active_external_sync_config_db, sync_task_board_for_orchestrator_db, task_board_host_local_db,
};
use super::task_board_evaluation::evaluate_task_board_async;
use super::task_board_github::run_task_board_github_automation_async;

pub(crate) async fn task_board_orchestrator_status_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let state = db.task_board_orchestrator_state().await?;
    status_from_state(db, state).await
}

pub(crate) async fn start_task_board_orchestrator_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    set_running_intent(db, true, true).await
}

pub(crate) async fn stop_task_board_orchestrator_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    set_running_intent(db, false, false).await
}

pub(crate) async fn task_board_orchestrator_settings_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    db.task_board_orchestrator_settings().await
}

pub(crate) async fn update_task_board_orchestrator_settings_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    let mut settings = db.task_board_orchestrator_settings().await?;
    apply_settings_update(&mut settings, request);
    settings.github_inbox = normalize_github_inbox(&settings.github_inbox)?;
    settings.todoist_inbox = normalize_todoist_inbox(&settings.todoist_inbox);
    db.replace_task_board_orchestrator_settings(&settings)
        .await?;
    Ok(settings)
}

pub(crate) async fn run_task_board_orchestrator_once_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let mut prepared = prepare_run(db, request, &settings).await?;
    let mut progress = (None, None);
    match execute_run(db, &settings, &mut prepared, &mut progress).await {
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
) -> Result<TaskBoardOrchestratorPreparedRun, CliError> {
    let input = dispatch_input(request, settings);
    let run_id = format!("task-board-run-{}", Uuid::new_v4().simple());
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
) -> Result<(DispatchExecutionSummary, TaskBoardEvaluationSummary), CliError> {
    sync_github_tasks(db, settings, prepared).await?;
    let dispatch = dispatch_task_board_async(&dispatch_request(&prepared.input), db).await?;
    progress.0 = Some(dispatch.clone());
    record_tick(
        db,
        &prepared.run_id,
        &prepared.started_at,
        prepared.input.dry_run,
        TaskBoardOrchestratorTickPhase::Evaluation,
    )
    .await?;
    let evaluation = evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            item_id: prepared.input.item_id.clone(),
            status: None,
            dry_run: prepared.input.dry_run,
        },
        db,
    )
    .await?;
    progress.1 = Some(evaluation.clone());
    let items = items_for_input(db, &prepared.input).await?;
    run_task_board_github_automation_async(settings, &prepared.input, &items, db).await?;
    Ok((dispatch, evaluation))
}

async fn sync_github_tasks(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
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
    prepared.sync = sync_task_board_for_orchestrator_db(
        db,
        &TaskBoardSyncRequest {
            status: prepared.input.status,
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: prepared.input.dry_run,
        },
    )
    .await?;
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
    Ok(build_audit_summary_with_policy(items, policy, switches))
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

fn dispatch_request(input: &TaskBoardOrchestratorDispatchInput) -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest {
        item_id: input.item_id.clone(),
        status: input.status,
        dry_run: input.dry_run,
        project_dir: input.project_dir.clone(),
        actor: input.actor.clone(),
    }
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

async fn set_running_intent(
    db: &AsyncDaemonDb,
    enabled: bool,
    running: bool,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let mut state = db.task_board_orchestrator_state().await?;
    state.enabled = enabled;
    state.running = running;
    db.replace_task_board_orchestrator_state(&state).await?;
    status_from_state(db, state).await
}

async fn status_from_state(
    db: &AsyncDaemonDb,
    state: TaskBoardOrchestratorState,
) -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let held_dispatches = db.held_task_board_dispatch_summary().await?;
    let machine = task_board_host_local_db(db).await.ok();
    let items = db.list_task_board_items(None).await?;
    let items = items.iter().filter(|item| {
        machine
            .as_ref()
            .is_none_or(|machine| machine.accepts_any(&item.target_project_types))
    });
    let workflow_execution_counts = workflow_statuses()
        .into_iter()
        .filter_map(|status| {
            let count = items
                .clone()
                .filter(|item| item.workflow.status == status)
                .count();
            (count > 0).then_some(TaskBoardWorkflowExecutionCount { status, count })
        })
        .collect();
    Ok(TaskBoardOrchestratorStatusResponse {
        enabled: state.enabled,
        running: state.running,
        step_mode: settings.step_mode,
        held_dispatches,
        current_tick: state.current_tick,
        last_run: state.last_run,
        workflow_execution_counts,
        settings,
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "settings patch semantics intentionally distinguish omitted, set, and explicit clear fields"
)]
fn apply_settings_update(
    settings: &mut TaskBoardOrchestratorSettings,
    update: &TaskBoardOrchestratorSettingsUpdateRequest,
) {
    if let Some(step_mode) = update.step_mode {
        settings.step_mode = step_mode;
    }
    if let Some(workflows) = &update.enabled_workflows {
        settings.enabled_workflows.clone_from(workflows);
    }
    if let Some(dry_run_default) = update.dry_run_default {
        settings.dry_run_default = dry_run_default;
    }
    if update.clear_dispatch_status_filter {
        settings.dispatch_status_filter = None;
    } else if let Some(status) = update.dispatch_status_filter {
        settings.dispatch_status_filter = Some(status.canonical_persisted_status());
    }
    if update.clear_project_dir {
        settings.project_dir = None;
    } else if let Some(project_dir) = &update.project_dir {
        settings.project_dir = Some(project_dir.clone());
    }
    if let Some(github_project) = &update.github_project {
        settings.github_project.clone_from(github_project);
    }
    if let Some(github_inbox) = &update.github_inbox {
        settings.github_inbox.clone_from(github_inbox);
    }
    if let Some(todoist_inbox) = &update.todoist_inbox {
        settings.todoist_inbox.clone_from(todoist_inbox);
    }
    if let Some(policy_version) = &update.policy_version {
        settings.policy_version.clone_from(policy_version);
    }
}

fn normalize_github_inbox(
    inbox: &TaskBoardGitHubInboxConfig,
) -> Result<TaskBoardGitHubInboxConfig, CliError> {
    let mut repositories = Vec::with_capacity(inbox.repositories.len());
    let mut seen = BTreeSet::new();
    for repository in &inbox.repositories {
        let Some(repository) = normalize_repository_slug(Some(repository.as_str())) else {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "invalid task-board github inbox repository '{repository}', expected owner/repo"
            ))));
        };
        if seen.insert(repository.clone()) {
            repositories.push(repository);
        }
    }
    Ok(TaskBoardGitHubInboxConfig {
        repositories,
        label_filter: normalize_strings(&inbox.label_filter),
    })
}

fn normalize_todoist_inbox(inbox: &TaskBoardTodoistInboxConfig) -> TaskBoardTodoistInboxConfig {
    TaskBoardTodoistInboxConfig {
        project_filter: normalize_strings(&inbox.project_filter),
    }
}

fn normalize_strings(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .iter()
        .filter_map(|value| {
            let value = value.trim();
            (!value.is_empty() && seen.insert(value.to_owned())).then(|| value.to_owned())
        })
        .collect()
}

const fn workflow_statuses() -> [TaskBoardWorkflowStatus; 6] {
    [
        TaskBoardWorkflowStatus::Idle,
        TaskBoardWorkflowStatus::Running,
        TaskBoardWorkflowStatus::Paused,
        TaskBoardWorkflowStatus::Completed,
        TaskBoardWorkflowStatus::Failed,
        TaskBoardWorkflowStatus::Cancelled,
    ]
}
