use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use crate::daemon::db::{CliError, db_error, utc_now};

/// Bounds the ancestor walk in [`check_parent_assignment_in_tx`] so a
/// corrupted chain fails closed with a clear error instead of looping forever.
const MAX_PARENT_CHAIN_DEPTH: u32 = 10_000;

/// Whether a parent assignment is semantically valid, distinct from a
/// storage failure: callers that need to isolate a rejected parent (restore)
/// must never mistake a SQL/connection error for `Invalid` and silently
/// discard it -- only `Err` means the transaction should abort.
pub(in crate::daemon::db::task_board) enum ParentAssignmentValidation {
    Valid,
    Invalid(String),
}

/// Checks whether a parent assignment would create a cycle or point at a
/// missing or deleted item. The direct parent must exist and be live;
/// ancestors further up are trusted to be live because deleting an item
/// always clears its children's `parent_item_id` in the same transaction.
/// `Err` is reserved for genuine query failures.
pub(in crate::daemon::db::task_board) async fn check_parent_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    parent_id: &str,
) -> Result<ParentAssignmentValidation, CliError> {
    let mut current = parent_id.to_owned();
    let mut first_hop = true;
    let mut remaining_hops = MAX_PARENT_CHAIN_DEPTH;
    loop {
        if current == item_id {
            return Ok(ParentAssignmentValidation::Invalid(format!(
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
            return Ok(ParentAssignmentValidation::Invalid(format!(
                "task-board parent '{current}' not found"
            )));
        };
        if first_hop && deleted_at.is_some() {
            return Ok(ParentAssignmentValidation::Invalid(format!(
                "task-board parent '{current}' is deleted"
            )));
        }
        first_hop = false;
        match next_parent {
            Some(parent) => {
                if remaining_hops == 0 {
                    return Ok(ParentAssignmentValidation::Invalid(format!(
                        "task-board parent chain for '{item_id}' exceeds max depth"
                    )));
                }
                remaining_hops -= 1;
                current = parent;
            }
            None => break,
        }
    }
    Ok(ParentAssignmentValidation::Valid)
}

/// Compute the next stable append-order slot among `parent_id`'s children.
pub(in crate::daemon::db::task_board) async fn next_child_order_in_tx(
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
/// item is ever left pointing at a deleted parent. Returns each affected
/// child's id and its resulting revision, so a caller recording a single
/// audit event for the whole mutation (a provider-exclusion hide, for
/// example) can report exactly what else changed.
pub(in crate::daemon::db::task_board) async fn clear_children_parent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    parent_id: &str,
) -> Result<Vec<(String, i64)>, CliError> {
    query_as::<_, (String, i64)>(
        "UPDATE task_board_items
         SET parent_item_id = NULL, child_order = 0, updated_at = ?2, revision = revision + 1
         WHERE parent_item_id = ?1
         RETURNING item_id, revision",
    )
    .bind(parent_id)
    .bind(utc_now())
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "clear task board children of '{parent_id}': {error}"
        ))
    })
}
