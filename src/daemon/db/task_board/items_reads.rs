use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::items::TaskBoardItemSnapshot;
use super::lane_order::TaskBoardItemsSnapshot;
use super::mapper::item_from_rows;
use super::rows::{ExternalRefRow, ItemRow};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, sort_task_board_items};

impl AsyncDaemonDb {
    /// Read a single consistent item-list sequence and per-item revisions.
    pub(crate) async fn task_board_items_snapshot(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<TaskBoardItemsSnapshot, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item snapshot: {error}")))?;
        let items_change_seq = query_scalar::<_, i64>(
            "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1",
        )
        .bind(ITEMS_CHANGE_SCOPE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board item sequence: {error}")))?
        .unwrap_or(0);
        let mut items = load_item_snapshots_in_tx(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item snapshot: {error}")))?;
        let status = status.map(TaskBoardStatus::canonical_persisted_status);
        items.retain(|snapshot| {
            !snapshot.item.is_deleted()
                && status.is_none_or(|expected| snapshot.item.status == expected)
        });
        sort_item_snapshots(&mut items);
        Ok(TaskBoardItemsSnapshot {
            items,
            items_change_seq,
        })
    }

    /// Test a picked item against its list sequence and row revision.
    pub(crate) async fn task_board_item_snapshot_is_current(
        &self,
        item_id: &str,
        item_revision: i64,
        items_change_seq: i64,
    ) -> Result<bool, CliError> {
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin task board pick revalidation: {error}"))
            })?;
        let current_sequence = query_scalar::<_, i64>(
            "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1",
        )
        .bind(ITEMS_CHANGE_SCOPE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board pick sequence: {error}")))?
        .unwrap_or(0);
        let current_revision = query_scalar::<_, i64>(
            "SELECT revision FROM task_board_items WHERE item_id = ?1 AND deleted_at IS NULL",
        )
        .bind(item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "read task-board pick revision '{item_id}': {error}"
            ))
        })?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board pick revalidation: {error}")))?;
        Ok(current_sequence == items_change_seq && current_revision == Some(item_revision))
    }

    /// List Task Board items including tombstones.
    pub(crate) async fn list_task_board_items_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        Ok(self
            .list_task_board_item_snapshots_including_deleted()
            .await?
            .into_iter()
            .map(|snapshot| snapshot.item)
            .collect())
    }

    /// Like [`list_task_board_items_including_deleted`], but keeps each
    /// item's row revision, for a batch caller that needs to CAS an exact
    /// matched revision without a second point read.
    pub(crate) async fn list_task_board_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItemSnapshot>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item list: {error}")))?;
        let mut snapshots = load_item_snapshots_in_tx(&mut transaction).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item list: {error}")))?;
        sort_item_snapshots(&mut snapshots);
        Ok(snapshots)
    }
}

async fn load_item_snapshots_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<TaskBoardItemSnapshot>, CliError> {
    let rows = query_as::<_, ItemRow>("SELECT * FROM task_board_items")
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("list task board snapshot rows: {error}")))?;
    let refs = query_as::<_, ExternalRefRow>(
        "SELECT item_id, position, provider, external_id, url, sync_state_json
         FROM task_board_external_refs ORDER BY item_id, position",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("list task board snapshot refs: {error}")))?;
    let mut refs_by_item = BTreeMap::<String, Vec<ExternalRefRow>>::new();
    for reference in refs {
        refs_by_item
            .entry(reference.item_id.clone())
            .or_default()
            .push(reference);
    }
    let mut snapshots = Vec::with_capacity(rows.len());
    for row in rows {
        let refs = refs_by_item.remove(&row.item_id).unwrap_or_default();
        let (item, item_revision) = item_from_rows(row, refs)?;
        snapshots.push(TaskBoardItemSnapshot {
            item,
            item_revision,
        });
    }
    Ok(snapshots)
}

fn sort_item_snapshots(snapshots: &mut [TaskBoardItemSnapshot]) {
    let mut ordered = snapshots
        .iter()
        .map(|snapshot| snapshot.item.clone())
        .collect::<Vec<_>>();
    sort_task_board_items(&mut ordered);
    let mut by_id = snapshots
        .iter()
        .cloned()
        .map(|snapshot| (snapshot.item.id.clone(), snapshot))
        .collect::<BTreeMap<_, _>>();
    for (destination, item) in snapshots.iter_mut().zip(ordered) {
        *destination = by_id
            .remove(&item.id)
            .expect("sorted task-board snapshot id exists");
    }
}
