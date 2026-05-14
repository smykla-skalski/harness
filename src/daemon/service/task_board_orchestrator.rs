use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
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
    ExternalProvider, ExternalSyncConfig, ExternalSyncDirection, TaskBoardOrchestrator,
    TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorTickPhase, TaskBoardStatus, build_audit_summary, default_board_root,
};

use super::task_board::{
    dispatch_task_board, dispatch_task_board_async, run_task_board_sync_blocking_with_config,
    sync_task_board_async_with_config,
};
use super::task_board_evaluation::{evaluate_task_board, evaluate_task_board_async};
use super::task_board_github::{
    run_task_board_github_automation, run_task_board_github_automation_async,
};
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

/// Run one task-board orchestrator tick through the async daemon DB path.
///
/// # Errors
/// Returns `CliError` when summaries, dispatch, or state persistence fails.
pub(crate) async fn run_task_board_orchestrator_once_async(
    request: &TaskBoardOrchestratorRunOnceRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let orchestrator = orchestrator();
    let mut prepared = orchestrator.prepare_run(request)?;
    if let Err(error) = sync_github_tasks_async(&orchestrator, &mut prepared).await {
        orchestrator.fail_run(&prepared, &error)?;
        return Err(error);
    }
    let dispatch_request = dispatch_request_from_input(&prepared.input);
    let dispatch = match dispatch_task_board_async(&dispatch_request, async_db).await {
        Ok(dispatch) => dispatch,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    orchestrator.record_run_phase(&prepared, TaskBoardOrchestratorTickPhase::Evaluation)?;
    let evaluation = match evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            item_id: prepared.input.item_id.clone(),
            status: None,
            dry_run: prepared.input.dry_run,
        },
        async_db,
    )
    .await
    {
        Ok(evaluation) => evaluation,
        Err(error) => {
            orchestrator.fail_run(&prepared, &error)?;
            return Err(error);
        }
    };
    let items = orchestrator.items_for_input(&prepared.input)?;
    let board_root = default_board_root();
    if let Err(error) = run_task_board_github_automation_async(
        &board_root,
        &orchestrator.settings()?,
        &prepared.input,
        &items,
        async_db,
    )
    .await
    {
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

async fn sync_github_tasks_async(
    orchestrator: &TaskBoardOrchestrator,
    prepared: &mut TaskBoardOrchestratorPreparedRun,
) -> Result<(), CliError> {
    let Some(config) = github_sync_config(orchestrator, &prepared.input)? else {
        return Ok(());
    };
    let sync = sync_task_board_async_with_config(&sync_request(&prepared.input), config).await?;
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
    {
        return Ok(None);
    }
    let config = external_sync_config_for_repository(github_repository(&settings).as_deref());
    if config.token_for(ExternalProvider::GitHub).is_none() || config.github_repository().is_none()
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
mod tests {
    use std::path::PathBuf;

    use temp_env::with_vars;
    use tempfile::tempdir;

    use super::*;
    use crate::task_board::{
        ExternalSyncAction, ExternalSyncOperation, GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV,
        HARNESS_GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_TOKEN_ENV, HARNESS_TODOIST_TOKEN_ENV,
        TaskBoardGitHubProjectConfig, TaskBoardItem, TaskBoardStore, TaskBoardSyncSummary,
        TaskBoardWorkflowStatus,
    };

    #[test]
    fn sync_github_tasks_uses_settings_repository_fallback_before_dispatch() {
        let temp = tempdir().expect("tempdir");
        with_vars(
            [
                (HARNESS_GITHUB_TOKEN_ENV, Some(" token ")),
                (GH_TOKEN_ENV, None::<&str>),
                (HARNESS_GITHUB_REPOSITORY_ENV, None::<&str>),
                (GITHUB_REPOSITORY_ENV, None::<&str>),
                (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
            ],
            || {
                let root = temp.path().join("board");
                let board = TaskBoardStore::new(root.clone());
                let mut item = TaskBoardItem::new(
                    "task-1".to_string(),
                    "Synced task".to_string(),
                    String::new(),
                    "2026-05-14T00:00:00Z".to_string(),
                );
                item.status = TaskBoardStatus::Todo;
                item.workflow.status = TaskBoardWorkflowStatus::Idle;
                board.create("Synced task", "", item).expect("create item");

                let orchestrator = TaskBoardOrchestrator::new(root);
                orchestrator
                    .update_settings(&TaskBoardOrchestratorSettingsUpdateRequest {
                        github_project: Some(TaskBoardGitHubProjectConfig::new(
                            "owner",
                            "sync-fallback-repo",
                            PathBuf::new(),
                        )),
                        ..TaskBoardOrchestratorSettingsUpdateRequest::default()
                    })
                    .expect("update settings");
                let mut prepared = orchestrator
                    .prepare_run(&TaskBoardOrchestratorRunOnceRequest::default())
                    .expect("prepare run");

                let mut captured_request = None;
                let mut captured_config = None;
                sync_github_tasks_with_runner(&orchestrator, &mut prepared, |request, config| {
                    captured_request = Some(request.clone());
                    captured_config = Some(config);
                    Ok(TaskBoardSyncSummary {
                        total: 1,
                        providers: Vec::new(),
                        operations: vec![ExternalSyncOperation {
                            provider: ExternalProvider::GitHub,
                            action: ExternalSyncAction::Pull,
                            board_item_id: Some("github-7".to_string()),
                            external_id: Some("7".to_string()),
                            url: None,
                            dry_run: true,
                            applied: false,
                        }],
                    })
                })
                .expect("sync github tasks");

                let request = captured_request.expect("captured request");
                let config = captured_config.expect("captured config");
                assert_eq!(request.provider, Some(ExternalProvider::GitHub));
                assert_eq!(request.direction, ExternalSyncDirection::Pull);
                assert_eq!(request.status, Some(TaskBoardStatus::Todo));
                assert!(request.dry_run);
                assert_eq!(config.token_for(ExternalProvider::GitHub), Some("token"));
                assert_eq!(config.github_repository(), Some("owner/sync-fallback-repo"));
                assert_eq!(prepared.sync.operations.len(), 1);
                assert_eq!(prepared.audit.total, 1);
            },
        );
    }

    #[test]
    fn sync_github_tasks_skips_item_scoped_runs() {
        let temp = tempdir().expect("tempdir");
        with_vars(
            [
                (HARNESS_GITHUB_TOKEN_ENV, Some("token")),
                (GH_TOKEN_ENV, None::<&str>),
                (HARNESS_GITHUB_REPOSITORY_ENV, Some("owner/repo")),
                (GITHUB_REPOSITORY_ENV, None::<&str>),
                (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
            ],
            || {
                let root = temp.path().join("board");
                let board = TaskBoardStore::new(root.clone());
                let mut item = TaskBoardItem::new(
                    "task-1".to_string(),
                    "Scoped task".to_string(),
                    String::new(),
                    "2026-05-14T00:00:00Z".to_string(),
                );
                item.status = TaskBoardStatus::Todo;
                board.create("Scoped task", "", item).expect("create item");

                let orchestrator = TaskBoardOrchestrator::new(root);
                let mut prepared = orchestrator
                    .prepare_run(&TaskBoardOrchestratorRunOnceRequest {
                        item_id: Some("task-1".to_string()),
                        ..TaskBoardOrchestratorRunOnceRequest::default()
                    })
                    .expect("prepare scoped run");
                let mut invoked = false;
                sync_github_tasks_with_runner(&orchestrator, &mut prepared, |_, _| {
                    invoked = true;
                    Ok(TaskBoardSyncSummary {
                        total: 0,
                        providers: Vec::new(),
                        operations: Vec::new(),
                    })
                })
                .expect("skip scoped sync");

                assert!(!invoked);
                assert!(prepared.sync.operations.is_empty());
            },
        );
    }
}
