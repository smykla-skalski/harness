use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::{
    TaskBoardDispatchRequest, TaskBoardEvaluateRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse,
    TaskBoardSyncRequest, TaskBoardSyncResponse,
};
use crate::errors::CliError;
use crate::task_board::github::GitHubAutomation;
use crate::task_board::orchestrator::TaskBoardOrchestratorPreparedRun;
use crate::task_board::{
    ExternalProvider, ExternalSyncConfig, ExternalSyncConflictPolicy, ExternalSyncDirection,
    TaskBoardOrchestrator, TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorTickPhase, TaskBoardStatus, build_audit_summary, default_board_root,
};

use super::task_board::{dispatch_task_board, run_task_board_sync_blocking_with_config};
use super::task_board_evaluation::evaluate_task_board;
use super::task_board_github::run_task_board_github_automation;
use super::task_board_runtime::external_sync_config_for_repository;

/// Load task-board orchestrator status from durable JSON state.
///
/// # Errors
/// Returns `CliError` when state, settings, or board items cannot be read.
pub fn task_board_orchestrator_status() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().status()
}

/// Persist task-board orchestrator start intent.
///
/// # Errors
/// Returns `CliError` when durable state cannot be read or written.
pub fn start_task_board_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().start()
}

/// Persist task-board orchestrator stop intent.
///
/// # Errors
/// Returns `CliError` when durable state cannot be read or written.
pub fn stop_task_board_orchestrator() -> Result<TaskBoardOrchestratorStatusResponse, CliError> {
    orchestrator().stop()
}

/// Load task-board orchestrator settings.
///
/// # Errors
/// Returns `CliError` when settings cannot be read.
pub fn task_board_orchestrator_settings() -> Result<TaskBoardOrchestratorSettingsResponse, CliError>
{
    orchestrator().settings()
}

/// Persist task-board orchestrator settings.
///
/// # Errors
/// Returns `CliError` when settings cannot be read or written.
pub fn update_task_board_orchestrator_settings(
    request: &TaskBoardOrchestratorSettingsUpdateRequest,
) -> Result<TaskBoardOrchestratorSettingsResponse, CliError> {
    orchestrator().update_settings(request)
}

/// Run one task-board orchestrator tick through the sync daemon DB path.
///
/// # Errors
/// Returns `CliError` when summaries, dispatch, or state persistence fails.
pub fn run_task_board_orchestrator_once(
    request: &TaskBoardOrchestratorRunOnceRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let orchestrator = orchestrator();
    let mut prepared = orchestrator.prepare_run(request)?;
    if let Err(error) = sync_github_tasks(&orchestrator, &mut prepared) {
        orchestrator.fail_run(&prepared, &error)?;
        return Err(error);
    }
    let dispatch = match dispatch_task_board(&dispatch_request_from_input(&prepared.input), db) {
        Ok(dispatch) => dispatch,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.record_run_phase(&prepared, TaskBoardOrchestratorTickPhase::Evaluation)?;
    let evaluation = match evaluate_task_board(
        &TaskBoardEvaluateRequest {
            item_id: prepared.input.item_id.clone(),
            status: None,
            dry_run: prepared.input.dry_run,
        },
        db,
    ) {
        Ok(evaluation) => evaluation,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    let items = orchestrator.items_for_input(&prepared.input)?;
    let board_root = default_board_root();
    if let Err(error) = run_task_board_github_automation(
        &board_root,
        &orchestrator.settings()?,
        &prepared.input,
        &items,
        db,
    ) {
        orchestrator.fail_run(&prepared, &error)?;
        return Err(error);
    }
    orchestrator.complete_run_with_evaluation(prepared, dispatch, Some(evaluation))
}

fn orchestrator() -> TaskBoardOrchestrator {
    TaskBoardOrchestrator::new(default_board_root())
}

fn dispatch_request_from_input(
    input: &TaskBoardOrchestratorDispatchInput,
) -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest {
        item_id: input.item_id.clone(),
        status: input.status,
        dry_run: input.dry_run,
        project_dir: input.project_dir.clone(),
        actor: input.actor.clone(),
    }
}

fn sync_github_tasks(
    orchestrator: &TaskBoardOrchestrator,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
) -> Result<(), CliError> {
    sync_github_tasks_with_runner(orchestrator, prepared, |request, config| {
        run_task_board_sync_blocking_with_config(request, config)
    })
}

fn sync_github_tasks_with_runner<F>(
    orchestrator: &TaskBoardOrchestrator,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
    run_sync: F,
) -> Result<(), CliError>
where
    F: FnOnce(&TaskBoardSyncRequest, ExternalSyncConfig) -> Result<TaskBoardSyncResponse, CliError>,
{
    let Some(config) = github_sync_config(orchestrator, &prepared.input)? else {
        return Ok(());
    };
    let sync = run_sync(&sync_request(&prepared.input), config)?;
    refresh_prepared_run(orchestrator, prepared, sync)
}

fn github_sync_config(
    orchestrator: &TaskBoardOrchestrator,
    input: &TaskBoardOrchestratorDispatchInput,
) -> Result<Option<ExternalSyncConfig>, CliError> {
    if input.item_id.is_some()
        || input
            .status
            .is_some_and(|status| status != TaskBoardStatus::Todo)
    {
        return Ok(None);
    }
    let settings = orchestrator.settings()?;
    if !settings
        .github_project
        .enabled_automations
        .enables(GitHubAutomation::SyncTaskBoard)
        && settings.github_inbox.repositories.is_empty()
    {
        return Ok(None);
    }
    let mut config = external_sync_config_for_repository(
        github_repository(&settings).as_deref(),
        &settings.github_inbox.repositories,
    );
    config = config.with_github_import_labels_override(&settings.github_inbox.label_filter);
    config =
        config.with_todoist_import_project_ids_override(&settings.todoist_inbox.project_filter);
    if config.token_for(ExternalProvider::GitHub).is_none()
        || (config.github_repository().is_none() && config.github_inbox_repositories().is_empty())
    {
        return Ok(None);
    }
    Ok(Some(config))
}

fn github_repository(settings: &TaskBoardOrchestratorSettings) -> Option<String> {
    let project = &settings.github_project;
    (!project.owner.trim().is_empty() && !project.repo.trim().is_empty())
        .then(|| project.repository_slug())
}

fn sync_request(input: &TaskBoardOrchestratorDispatchInput) -> TaskBoardSyncRequest {
    TaskBoardSyncRequest {
        status: input.status,
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: input.dry_run,
    }
}

fn refresh_prepared_run(
    orchestrator: &TaskBoardOrchestrator,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
    sync: TaskBoardSyncResponse,
) -> Result<(), CliError> {
    prepared.sync = sync;
    prepared.audit = build_audit_summary(&orchestrator.items_for_input(&prepared.input)?);
    Ok(())
}

#[cfg(test)]
mod tests;
