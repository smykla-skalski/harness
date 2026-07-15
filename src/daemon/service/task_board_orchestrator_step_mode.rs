use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::TaskBoardDispatchRequest;
use crate::errors::CliError;
use crate::task_board::{TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings};

use super::task_board::pick_task_board_dispatch_async;

pub(super) async fn scoped_dispatch_request(
    db: &AsyncDaemonDb,
    settings: &TaskBoardOrchestratorSettings,
    input: &TaskBoardOrchestratorDispatchInput,
) -> Result<Option<TaskBoardDispatchRequest>, CliError> {
    let mut request = TaskBoardDispatchRequest {
        item_id: input.item_id.clone(),
        status: input.status,
        dry_run: input.dry_run,
        project_dir: input.project_dir.clone(),
        actor: input.actor.clone(),
    };
    if !settings.step_mode || input.dry_run || input.item_id.is_some() {
        return Ok(Some(request));
    }
    request.item_id = pick_task_board_dispatch_async(db)
        .await?
        .selection
        .map(|selection| selection.item.id);
    Ok(request.item_id.is_some().then_some(request))
}
