use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardListItemsRequest, TaskBoardListItemsResponse};
use crate::errors::CliError;
use crate::task_board::build_progress_rollups;
use std::collections::HashMap;

pub(crate) async fn list_task_board_items_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    // Roll-ups always derive from the full live set, never the status-filtered
    // `items` below, or a status filter would silently undercount siblings
    // that don't match it.
    let snapshot = db.task_board_items_snapshot(None).await?;
    let all_items = snapshot
        .items
        .iter()
        .map(|item| item.item.clone())
        .collect::<Vec<_>>();
    let progress_rollups = build_progress_rollups(&all_items);
    let selected = match request.status {
        Some(status) => {
            let status = status.canonical_persisted_status();
            snapshot
                .items
                .into_iter()
                .filter(|item| item.item.status.canonical_persisted_status() == status)
                .collect()
        }
        None => snapshot.items,
    };
    let item_revisions = selected
        .iter()
        .map(|item| (item.item.id.clone(), item.item_revision))
        .collect::<HashMap<_, _>>();
    let items = selected.into_iter().map(|item| item.item).collect();
    Ok(TaskBoardListItemsResponse {
        items,
        items_change_seq: snapshot.items_change_seq,
        item_revisions,
        progress_rollups,
    })
}
