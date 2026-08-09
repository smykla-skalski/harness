//! Reconcile progress reported while a dispatch claim was still starting.

use sqlx::{Sqlite, Transaction};

use super::item_tx_ext::TaskBoardItemTxExt;
use super::work_item_progress::project_item_in_tx;
use super::work_item_progress_rows::load_progress_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::TaskBoardItem;

pub(in crate::daemon::db::task_board) async fn reconcile_progress_after_dispatch_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
) -> Result<TaskBoardItem, CliError> {
    let (item, item_revision) = transaction
        .load_item_in_tx(board_item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
    let Some(work_item_id) = item.work_item_id.as_deref() else {
        return Ok(item);
    };
    let Some(loaded) = load_progress_in_tx(transaction, board_item_id, work_item_id).await? else {
        return Ok(item);
    };
    Ok(
        project_item_in_tx(transaction, item, item_revision, &loaded.progress)
            .await?
            .item,
    )
}
