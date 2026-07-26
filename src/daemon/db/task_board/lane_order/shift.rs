//! The row writes a lane transition performs: storing the transitioning item
//! itself, and re-storing the neighbours its placement moved.

use sqlx::{Sqlite, Transaction};

use super::super::items::{insert_item_in_tx, replace_item_in_tx};
use super::{LaneEntry, TaskBoardLaneShift, clear_changed_anchors_in_tx, next_item_revision};
use crate::daemon::db::CliError;
use crate::task_board::TaskBoardItem;

/// Stores the transitioning item. Whether the row already exists is the only
/// difference between the two writes, and the caller knows it from `before`.
pub(super) async fn store_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    item_revision: i64,
    replacing: bool,
) -> Result<(), CliError> {
    if replacing {
        replace_item_in_tx(transaction, item, item_revision).await
    } else {
        insert_item_in_tx(transaction, item, item_revision).await
    }
}

/// Re-stores every neighbour whose placement `normalize_lane_entries` changed
/// and reports the shifts. The transitioning item can be among them, so the
/// caller drops it from the reported shifts and stores it at its own revision.
pub(super) async fn shift_lane_entries_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    entries: &[LaneEntry],
    previous: Option<&TaskBoardItem>,
    item: &TaskBoardItem,
) -> Result<Vec<TaskBoardLaneShift>, CliError> {
    clear_changed_anchors_in_tx(transaction, entries, previous, item).await?;
    let mut shifted = Vec::new();
    for entry in entries.iter().filter(|entry| entry.before != entry.item) {
        let item_revision = next_item_revision(entry.revision)?;
        replace_item_in_tx(transaction, &entry.item, item_revision).await?;
        shifted.push(TaskBoardLaneShift {
            item_id: entry.item.id.clone(),
            item_revision,
        });
    }
    Ok(shifted)
}
