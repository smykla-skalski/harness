use crate::daemon::db::{AsyncDaemonDb, TaskBoardItemSnapshot};
use crate::task_board::TaskBoardProgressRollup;
use crate::task_board::progress_rollup::build_progress_rollups_from;
use harness_kernel::errors::CliError;
use harness_task_board_remote_viewer::{RevisionedTaskBoardItem, TaskBoardListProjectionSource};
use std::collections::HashMap;
use crate::daemon::db::task_board::prelude::*;

/// The whole live board, in board order, that one list read selects from.
///
/// Selection, paging, and viewer redaction happen at the transport edge, the
/// only layer that knows what the caller may read: a remote viewer has to
/// match against its own redacted projection, or a search would answer
/// questions about text that viewer can never read back.
pub(crate) struct TaskBoardListSource {
    /// Items stay paired with their revisions until paging chooses the rows
    /// that need wire-map keys. Building that map here would clone every live
    /// id even though one response returns at most one page.
    pub items: Vec<TaskBoardItemSnapshot>,
    pub items_change_seq: i64,
    pub progress_rollups: HashMap<String, TaskBoardProgressRollup>,
}

/// `harness-task-board-remote-viewer` never depends on `harness-daemon` --
/// its HTTP list-read call site converts this into its own mirrored shape
/// here, at the one place a `TaskBoardListSource` becomes a wire response.
impl From<TaskBoardListSource> for TaskBoardListProjectionSource {
    fn from(source: TaskBoardListSource) -> Self {
        Self {
            items: source
                .items
                .into_iter()
                .map(|snapshot| RevisionedTaskBoardItem {
                    item: snapshot.item,
                    item_revision: snapshot.item_revision,
                })
                .collect(),
            items_change_seq: source.items_change_seq,
            progress_rollups: source.progress_rollups,
        }
    }
}

pub(crate) async fn read_task_board_items_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardListSource, CliError> {
    let mut snapshot = db.task_board_items_snapshot(None).await?;
    let scope =
        super::super::task_board_repository_scope::TaskBoardRepositoryScope::load(db).await?;
    snapshot.items = scope.filter_snapshots(snapshot.items);
    // Roll-ups always derive from the full live set, never from the caller's
    // selection, or a filtered read would silently undercount siblings that
    // did not match it.
    let progress_rollups =
        build_progress_rollups_from(snapshot.items.iter().map(|snapshot| &snapshot.item));
    Ok(TaskBoardListSource {
        items: snapshot.items,
        items_change_seq: snapshot.items_change_seq,
        progress_rollups,
    })
}
