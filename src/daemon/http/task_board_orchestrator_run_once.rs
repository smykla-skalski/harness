use crate::daemon::protocol::{
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunOnceResponse,
};
use crate::errors::CliError;

use super::DaemonHttpState;

pub(super) async fn run(
    state: &DaemonHttpState,
    request: &TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    super::task_board_route_executor::run_once(state, request.clone()).await
}
