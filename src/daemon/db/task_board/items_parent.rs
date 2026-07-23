use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use crate::daemon::db::{CliError, db_error, utc_now};

/// Bounds the ancestor walk in [`ensure_parent_assignment_is_valid_in_tx`] so a
/// corrupted chain fails closed with a clear error instead of looping forever.
const MAX_PARENT_CHAIN_DEPTH: u32 = 10_000;

/// Reject a parent assignment that would create a cycle or point at a
/// missing or deleted item. The direct parent must exist and be live;
/// ancestors further up are trusted to be live because deleting an item
/// always clears its children's `parent_item_id` in the same transaction.
pub(super) async fn ensure_parent_assignment_is_valid_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    parent_id: &str,
) -> Result<(), CliError> {
    let mut current = parent_id.to_owned();
    let mut first_hop = true;
    let mut remaining_hops = MAX_PARENT_CHAIN_DEPTH;
    loop {
        if current == item_id {
            return Err(db_error(format!(
                "task-board item '{item_id}' cannot become an ancestor of itself"
            )));
        }
        let row = query_as::<_, (Option<String>, Option<String>)>(
            "SELECT parent_item_id, deleted_at FROM task_board_items WHERE item_id = ?1",
        )
        .bind(&current)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board parent '{current}': {error}")))?;
        let Some((next_parent, deleted_at)) = row else {
            return Err(db_error(format!("task-board parent '{current}' not found")));
        };
        if first_hop && deleted_at.is_some() {
            return Err(db_error(format!(
                "task-board parent '{current}' is deleted"
            )));
        }
        first_hop = false;
        match next_parent {
            Some(parent) => {
                if remaining_hops == 0 {
                    return Err(db_error(format!(
                        "task-board parent chain for '{item_id}' exceeds max depth"
                    )));
                }
                remaining_hops -= 1;
                current = parent;
            }
            None => break,
        }
    }
    Ok(())
}

/// Compute the next stable append-order slot among `parent_id`'s children.
pub(super) async fn next_child_order_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent_id: &str,
) -> Result<u32, CliError> {
    let max_order: Option<i64> =
        query_scalar("SELECT MAX(child_order) FROM task_board_items WHERE parent_item_id = ?1")
            .bind(parent_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| {
                db_error(format!(
                    "read task board child order '{parent_id}': {error}"
                ))
            })?;
    let next = max_order.unwrap_or(-1) + 1;
    u32::try_from(next)
        .map_err(|error| db_error(format!("task board child order overflow: {error}")))
}

/// Unparent every reference to `parent_id`, live or tombstoned, so deleting a
/// parent leaves its children intact rather than orphaned or hidden, and no
/// item is ever left pointing at a deleted parent.
pub(crate) async fn clear_children_parent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent_id: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_items
         SET parent_item_id = NULL, child_order = 0, updated_at = ?2, revision = revision + 1
         WHERE parent_item_id = ?1",
    )
    .bind(parent_id)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "clear task board children of '{parent_id}': {error}"
        ))
    })?;
    Ok(())
}
