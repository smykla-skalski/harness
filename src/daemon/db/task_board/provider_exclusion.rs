use sqlx::{Sqlite, Transaction, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::items::{
    TaskBoardMutation, bump_change_in_tx, clear_children_parent_in_tx, load_item_in_tx,
    validate_item,
};
use super::lane_order::{LaneTransitionKind, replace_with_lane_transition_in_tx};
use super::triage_audit::record_provider_exclusion_hidden_audit_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTombstoneCause};

impl AsyncDaemonDb {
    /// Tombstones an already-visible, pre-dispatch item because the provider
    /// now reports an exclusion label. Returns `None`, doing nothing, when
    /// the item is not eligible to be hidden this way: already deleted, past
    /// pre-dispatch (canonical status outside Backlog/Todo), or carrying
    /// durable dispatch/admission evidence of claimed or started work.
    /// Records exactly one typed audit event even when the item has no lane
    /// anchor to change. Clears any children's parent link first, mirroring
    /// the normal delete path, so a hidden umbrella never leaves a live child
    /// pointing at a tombstoned parent.
    pub(crate) async fn hide_task_board_item_for_provider_exclusion(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardMutation>, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board provider exclusion hide")
            .await?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        if !is_hideable_for_provider_exclusion_in_tx(&mut transaction, &item).await? {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit task board hide no-op: {error}")))?;
            return Ok(None);
        }
        let before = item.clone();
        item.deleted_at = Some(utc_now());
        item.tombstone_cause = Some(TaskBoardTombstoneCause::ProviderExclusion);
        item.updated_at = utc_now();
        validate_item(&item)?;
        clear_children_parent_in_tx(&mut transaction, item_id).await?;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before.clone(),
            revision,
            item,
            LaneTransitionKind::Generic,
        )
        .await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_provider_exclusion_hidden_audit_in_tx(&mut transaction, &before, &write, change_revision)
            .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board hide: {error}")))?;
        Ok(Some(TaskBoardMutation {
            item: write.item,
            item_revision: write.item_revision,
            change_revision,
        }))
    }
}

async fn is_hideable_for_provider_exclusion_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
) -> Result<bool, CliError> {
    if item.is_deleted() || item.work_item_id.is_some() || !item.kind.is_dispatchable() {
        return Ok(false);
    }
    if !matches!(
        item.status.canonical_persisted_status(),
        TaskBoardStatus::Backlog | TaskBoardStatus::Todo
    ) {
        return Ok(false);
    }
    Ok(!has_active_dispatch_intent_in_tx(transaction, &item.id).await?)
}

/// Mirrors the canonical "active" intent definition already enforced by
/// `idx_task_board_dispatch_active_item`: any admission state short of a
/// terminal `completed`/`failed` outcome means real work is reserved,
/// queued, or already underway and must never be silently hidden.
async fn has_active_dispatch_intent_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_intents
             WHERE item_id = ?1
               AND status IN (
                   'preparing', 'preparing_claimed', 'held', 'pending',
                   'workflow_prepared', 'starting'
               )
         )",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check task board dispatch admission: {error}")))
}

#[cfg(test)]
#[path = "provider_exclusion_tests.rs"]
mod tests;
