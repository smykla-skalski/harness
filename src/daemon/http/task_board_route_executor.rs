use tokio::task::spawn_blocking;

use crate::daemon::protocol::{
    TaskBoardDispatchRequest, TaskBoardDispatchResponse, TaskBoardEvaluateRequest,
    TaskBoardEvaluationResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::daemon::task_board_managed_agents::{
    start_workers_for_applied_dispatch, start_workers_for_run_once_status,
};
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
        return handle_dispatch_result(state, result, Some(async_db.as_ref())).await;
    }

    let result = {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::dispatch_task_board(&request, db_ref)
    };
    handle_dispatch_result(state, result, None).await
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
        return handle_run_once_result(state, result, Some(async_db.as_ref())).await;
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
    handle_run_once_result(state, result, None).await
}

async fn handle_dispatch_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardDispatchResponse, CliError>,
    async_db: Option<&crate::daemon::db::AsyncDaemonDb>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let response = result?;
    if !response.applied.is_empty() {
        start_workers_for_applied_dispatch(state, &response.applied).await?;
        broadcast_sessions_updated(state, async_db).await;
    }
    Ok(response)
}

async fn handle_run_once_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardOrchestratorRunOnceResponse, CliError>,
    async_db: Option<&crate::daemon::db::AsyncDaemonDb>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let status = result?;
    if status.last_run_applied_count() > 0 {
        start_workers_for_run_once_status(state, &status).await?;
        broadcast_sessions_updated(state, async_db).await;
    }
    Ok(status)
}

async fn broadcast_sessions_updated(
    state: &DaemonHttpState,
    async_db: Option<&crate::daemon::db::AsyncDaemonDb>,
) {
    if let Some(async_db) = async_db {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db)).await;
        return;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    service::broadcast_sessions_updated(&state.sender, db_ref);
}
