use tokio::task::spawn_blocking;

use crate::daemon::protocol::{
    TaskBoardDispatchRequest, TaskBoardDispatchResponse, TaskBoardEvaluateRequest,
    TaskBoardEvaluationResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::DaemonHttpState;

pub(crate) async fn dispatch(
    state: &DaemonHttpState,
    mut request: TaskBoardDispatchRequest,
) -> Result<TaskBoardDispatchResponse, CliError> {
    request.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    if let Some(async_db) = state.async_db.get() {
        let result = service::dispatch_task_board_async(&request, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|response| !response.applied.is_empty())
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::dispatch_task_board(&request, db_ref);
    if result
        .as_ref()
        .is_ok_and(|response| !response.applied.is_empty())
    {
        service::broadcast_sessions_updated(&state.sender, db_ref);
    }
    result
}

pub(crate) async fn evaluate(
    state: &DaemonHttpState,
    request: TaskBoardEvaluateRequest,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::evaluate_task_board_async(&request, async_db.as_ref()).await;
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::evaluate_task_board(&request, db_ref);
    if result.as_ref().is_ok_and(|response| response.updated > 0) {
        service::broadcast_sessions_updated(&state.sender, db_ref);
    }
    result
}

pub(crate) async fn run_once(
    state: &DaemonHttpState,
    mut request: TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    request.actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
    if let Some(async_db) = state.async_db.get() {
        let result =
            service::run_task_board_orchestrator_once_async(&request, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        return result;
    }

    let db = state.db.get().cloned();
    let result = spawn_blocking(move || {
        let db_guard = db.as_ref().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::run_task_board_orchestrator_once(&request, db_ref)
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("run task-board orchestrator fallback: {error}"))
                .into(),
        )
    });
    if result
        .as_ref()
        .is_ok_and(|status| status.last_run_applied_count() > 0)
    {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::broadcast_sessions_updated(&state.sender, db_ref);
    }
    result
}
