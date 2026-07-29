use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query, query_as};

use super::mapper::item_from_rows;
use super::projects::ensure_project_in_tx;
use super::rows::{ExternalRefRow, ItemRow};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardItem;
use crate::task_board::project::{ItemProjectAttribution, item_attribution};

impl AsyncDaemonDb {
    /// Run the attribution rules over every live item that holds no project,
    /// and return how many gained one.
    ///
    /// Attribution otherwise happens only on write, so widening the rules
    /// reaches a stored item only when something else edits it, and a synced
    /// item nobody touches upstream may never be rewritten. Widened rules ship
    /// in a new binary and a new binary means a restart, so re-running them at
    /// startup closes that gap without a migration per widening.
    ///
    /// # Errors
    /// Returns [`CliError`] when the board cannot be read or written.
    pub(crate) async fn reattribute_unattributed_task_board_items(
        &self,
    ) -> Result<usize, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board reattribution")
            .await?;
        let items = load_unattributed_items_in_tx(&mut transaction).await?;
        let mut attributed = 0;
        for item in items {
            if attribute_item_in_tx(&mut transaction, &item).await? {
                attributed += 1;
            }
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board reattribution: {error}")))?;
        Ok(attributed)
    }
}

async fn attribute_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
) -> Result<bool, CliError> {
    // A row selected for this pass holds no project, so `Assigned` cannot
    // reach here and `Unattributed` is the origin staying unknown.
    let ItemProjectAttribution::Register(source, slug) = item_attribution(item) else {
        return Ok(false);
    };
    let Some(project_id) = ensure_project_in_tx(transaction, source, &slug).await? else {
        return Ok(false);
    };
    // Neither `revision` nor `updated_at` moves: attribution is derived
    // metadata rather than an edit, and bumping either would make every board
    // client refetch over a boot that changed nothing they can see.
    query(
        "UPDATE task_board_items SET source_project_id = ?2
         WHERE item_id = ?1 AND source_project_id IS NULL",
    )
    .bind(&item.id)
    .bind(&project_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("attribute task board item '{}': {error}", item.id)))?;
    Ok(true)
}

/// Whole items rather than the three columns attribution reads today, so a rule
/// that starts reading a fourth repairs the same rows it now names, instead of
/// silently missing them against a projection nobody remembered to widen.
#[expect(
    clippy::cognitive_complexity,
    reason = "two queries, a group-by and a decode loop score 6 structurally; the \
              one tracing::warn! naming an item this build cannot read expands to \
              7 more points on its own, so no split reaches the threshold of 7"
)]
async fn load_unattributed_items_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let rows = query_as::<_, ItemRow>(
        "SELECT * FROM task_board_items
         WHERE source_project_id IS NULL AND deleted_at IS NULL",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("list unattributed task board items: {error}")))?;
    let refs = query_as::<_, ExternalRefRow>(
        "SELECT reference.item_id, reference.position, reference.provider,
                reference.external_id, reference.url, reference.sync_state_json
         FROM task_board_external_refs AS reference
         JOIN task_board_items AS item ON item.item_id = reference.item_id
         WHERE item.source_project_id IS NULL AND item.deleted_at IS NULL
         ORDER BY reference.item_id, reference.position",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("list unattributed task board refs: {error}")))?;
    let mut refs_by_item = BTreeMap::<String, Vec<ExternalRefRow>>::new();
    for reference in refs {
        refs_by_item
            .entry(reference.item_id.clone())
            .or_default()
            .push(reference);
    }
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let refs = refs_by_item.remove(&row.item_id).unwrap_or_default();
        let item_id = row.item_id.clone();
        // A row this build cannot decode is left in the state the pass found
        // it in. Raising here would cost every other item its mark, and at
        // startup it would cost the daemon its boot.
        match item_from_rows(row, refs) {
            Ok((item, _revision)) => items.push(item),
            Err(error) => tracing::warn!(
                item_id,
                %error,
                "skipped an unreadable item while reattributing the task board"
            ),
        }
    }
    Ok(items)
}

#[cfg(test)]
#[path = "projects_backfill_tests.rs"]
mod tests;
