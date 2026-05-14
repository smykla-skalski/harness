use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    TaskBoardDispatchRequest, TaskBoardEvaluateRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse, TaskBoardOrchestratorSettingsResponse,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatusResponse,
};
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardOrchestrator, TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorTickPhase,
    default_board_root,
};

use super::task_board::{dispatch_task_board, dispatch_task_board_async};
use super::task_board_evaluation::{evaluate_task_board, evaluate_task_board_async};

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
    let prepared = orchestrator.prepare_run(request)?;
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
    let prepared = orchestrator.prepare_run(request)?;
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
    orchestrator.complete_run_with_evaluation(prepared, dispatch, Some(evaluation))
}

fn orchestrator() -> TaskBoardOrchestrator {
    TaskBoardOrchestrator::new(default_board_root())
}

fn dispatch_request_from_input(
    input: &TaskBoardOrchestratorDispatchInput,
) -> TaskBoardDispatchRequest {
    TaskBoardDispatchRequest {
        status: input.status,
        dry_run: input.dry_run,
        project_dir: input.project_dir.clone(),
        actor: input.actor.clone(),
    }
}
