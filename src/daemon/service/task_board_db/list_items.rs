use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardItem, TaskBoardProgressRollup, build_progress_rollups};
use harness_kernel::errors::CliError;
use std::collections::HashMap;

/// The whole live board, in board order, that one list read selects from.
///
/// Selection, paging, and viewer redaction happen at the transport edge, the
/// only layer that knows what the caller may read: a remote viewer has to
/// match against its own redacted projection, or a search would answer
/// questions about text that viewer can never read back.
pub(crate) struct TaskBoardListSource {
    pub items: Vec<TaskBoardItem>,
    pub items_change_seq: i64,
    pub item_revisions: HashMap<String, i64>,
    pub progress_rollups: HashMap<String, TaskBoardProgressRollup>,
}

pub(crate) async fn read_task_board_items_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardListSource, CliError> {
    let snapshot = db.task_board_items_snapshot(None).await?;
    let item_revisions = snapshot
        .items
        .iter()
        .map(|item| (item.item.id.clone(), item.item_revision))
        .collect::<HashMap<_, _>>();
    let items = snapshot
        .items
        .into_iter()
        .map(|item| item.item)
        .collect::<Vec<_>>();
    // Roll-ups always derive from the full live set, never from the caller's
    // selection, or a filtered read would silently undercount siblings that
    // did not match it.
    let progress_rollups = build_progress_rollups(&items);
    Ok(TaskBoardListSource {
        items,
        items_change_seq: snapshot.items_change_seq,
        item_revisions,
        progress_rollups,
    })
}
