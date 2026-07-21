use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardListItemsRequest, TaskBoardListItemsResponse};
use crate::errors::CliError;
use crate::task_board::build_progress_rollups;

pub(crate) async fn list_task_board_items_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    // Roll-ups always derive from the full live set, never the status-filtered
    // `items` below, or a status filter would silently undercount siblings
    // that don't match it.
    let all_items = db.list_task_board_items(None).await?;
    let progress_rollups = build_progress_rollups(&all_items);
    let items = match request.status {
        Some(status) => {
            let status = status.canonical_persisted_status();
            all_items
                .into_iter()
                .filter(|item| item.status.canonical_persisted_status() == status)
                .collect()
        }
        None => all_items,
    };
    Ok(TaskBoardListItemsResponse {
        items,
        progress_rollups,
    })
}
