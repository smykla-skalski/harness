use tokio::task::spawn_blocking;

use crate::daemon::protocol::{
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};

use super::DaemonHttpState;

pub(super) async fn run(
    state: &DaemonHttpState,
    request: &TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result =
            service::run_task_board_orchestrator_once_async(request, async_db.as_ref()).await;
        if result
            .as_ref()
            .is_ok_and(|status| status.last_run_applied_count() > 0)
        {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        return result;
    }

    let db = state.db.get().cloned();
    let request_for_worker = request.clone();
    let result = spawn_blocking(move || {
        let db_guard = db.as_ref().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::run_task_board_orchestrator_once(&request_for_worker, db_ref)
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
