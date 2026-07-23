use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::lane_order::{
    LaneTransitionKind, LaneTransitionWrite, insert_with_lane_transition_in_tx,
    record_lane_transition_audit_in_tx, replace_with_lane_transition_in_tx,
};
use super::mapper::item_from_rows;
use super::rows::{ExternalRefRow, ItemRow};
use super::triage_apply::apply_builtin_v1_triage_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::infra::io;
use crate::task_board::types::{CURRENT_TASK_BOARD_ITEM_VERSION, MAX_TASK_BOARD_ESTIMATE};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, validate_lane_placement};

#[path = "items_lifecycle.rs"]
mod lifecycle;
use lifecycle::ensure_estimates_are_editable_in_tx;
pub(super) use lifecycle::{
    apply_task_board_item_status_transition_in_tx, ensure_workflow_item_mutation_allowed_in_tx,
};

#[path = "items_parent.rs"]
mod parent;
use parent::{
    clear_children_parent_in_tx, ensure_parent_assignment_is_valid_in_tx, next_child_order_in_tx,
};

#[path = "items_write.rs"]
mod write;
pub(super) use write::{insert_item_in_tx, replace_item_in_tx};

const SELECT_ITEM: &str = "SELECT * FROM task_board_items WHERE item_id = ?1";
const SELECT_REFS: &str = "SELECT item_id, position, provider, external_id, url, sync_state_json
    FROM task_board_external_refs WHERE item_id = ?1 ORDER BY position";

#[derive(Debug)]
pub(crate) struct TaskBoardMutation {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
    pub(crate) change_revision: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardItemSnapshot {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
}

impl AsyncDaemonDb {
    /// Insert one new Task Board item.
    #[expect(
        clippy::cognitive_complexity,
        reason = "sequential create/insert/triage/audit/commit steps, each already its own helper"
    )]
    pub(crate) async fn create_task_board_item(
        &self,
        mut item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        validate_item(&item)?;
        let mut transaction = self
            .begin_immediate_transaction("task board item create")
            .await?;
        reject_if_item_exists_in_tx(&mut transaction, &item.id).await?;
        let inserted = insert_with_lane_transition_in_tx(&mut transaction, item).await?;
        let write = apply_triage_after_insert_in_tx(&mut transaction, inserted).await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_transition_audit_in_tx(&mut transaction, &write, change_revision).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item create: {error}")))?;
        Ok(TaskBoardMutation {
            item: write.item,
            item_revision: write.item_revision,
            change_revision,
        })
    }

    /// Load one Task Board item, including tombstones.
    pub(crate) async fn task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.task_board_item_snapshot(item_id)
            .await
            .map(|snapshot| snapshot.item)
    }

    /// Load one Task Board item with the row revision used by automation CAS.
    pub(crate) async fn task_board_item_snapshot(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardItemSnapshot, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item load: {error}")))?;
        let (item, item_revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item load: {error}")))?;
        Ok(TaskBoardItemSnapshot {
            item,
            item_revision,
        })
    }

    /// List active Task Board items in the legacy stable ordering.
    pub(crate) async fn list_task_board_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut items = self.list_task_board_items_including_deleted().await?;
        let status = status.map(TaskBoardStatus::canonical_persisted_status);
        items.retain(|item| {
            !item.is_deleted() && status.is_none_or(|expected| item.status == expected)
        });
        Ok(items)
    }

    /// Atomically load and conditionally mutate one Task Board item.
    #[expect(
        clippy::cognitive_complexity,
        reason = "pre-existing sequential mutation/guard chain; triage is one more straight-line step"
    )]
    pub(crate) async fn update_task_board_item<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board item update")
            .await?;
        let (mut item, revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        let before = item.clone();
        let prior_estimates = (item.estimated_tokens, item.estimated_cost_microusd);
        let prior_parent_item_id = item.parent_item_id.clone();
        if !mutate(&mut item)? {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit task board item no-op: {error}")))?;
            return Ok(None);
        }
        if item.id != item_id {
            return Err(db_error(format!(
                "task-board mutation cannot change item id '{item_id}' to '{}'",
                item.id
            )));
        }
        if prior_estimates != (item.estimated_tokens, item.estimated_cost_microusd) {
            ensure_estimates_are_editable_in_tx(&mut transaction, item_id).await?;
        }
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        item.updated_at = utc_now();
        if item.parent_item_id != prior_parent_item_id {
            item.child_order = match item.parent_item_id.clone() {
                Some(parent_id) => {
                    ensure_parent_assignment_is_valid_in_tx(&mut transaction, item_id, &parent_id)
                        .await?;
                    next_child_order_in_tx(&mut transaction, &parent_id).await?
                }
                None => 0,
            };
        }
        apply_task_board_item_status_transition_in_tx(&mut transaction, &item).await?;
        if item.deleted_at.is_some() {
            clear_children_parent_in_tx(&mut transaction, item_id).await?;
        }
        let decided_at = item.updated_at.clone();
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, &decided_at).await?;
        let write = replace_with_lane_transition_in_tx(
            &mut transaction,
            before,
            revision,
            item,
            LaneTransitionKind::Generic,
        )
        .await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        record_lane_transition_audit_in_tx(&mut transaction, &write, change_revision).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item update: {error}")))?;
        Ok(Some(TaskBoardMutation {
            item: write.item,
            item_revision: write.item_revision,
            change_revision,
        }))
    }

    /// Tombstone one Task Board item.
    pub(crate) async fn delete_task_board_item(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardMutation, CliError> {
        self.update_task_board_item(item_id, |item| {
            item.deleted_at = Some(utc_now());
            Ok(true)
        })
        .await?
        .ok_or_else(|| db_error("task board delete unexpectedly produced no mutation"))
    }
}

async fn reject_if_item_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    if load_item_in_tx(transaction, item_id).await?.is_some() {
        return Err(db_error(format!(
            "task-board item '{item_id}' already exists"
        )));
    }
    Ok(())
}

/// Evaluate `BuiltInV1` against a just-inserted item and, only if it changed
/// status or placement, persist that through a follow-up automatic lane
/// transition. Returns the original insert write unchanged otherwise, so a
/// non-promoting create costs no extra revision bump.
async fn apply_triage_after_insert_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    inserted: LaneTransitionWrite,
) -> Result<LaneTransitionWrite, CliError> {
    let before_triage = inserted.item.clone();
    let mut item = inserted.item.clone();
    let decided_at = utc_now();
    apply_builtin_v1_triage_in_tx(transaction, &mut item, &decided_at).await?;
    if item == before_triage {
        return Ok(inserted);
    }
    replace_with_lane_transition_in_tx(
        transaction,
        before_triage,
        inserted.item_revision,
        item,
        LaneTransitionKind::Automatic,
    )
    .await
}

pub(super) async fn load_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<Option<(TaskBoardItem, i64)>, CliError> {
    let Some(row) = query_as::<_, ItemRow>(SELECT_ITEM)
        .bind(item_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board item '{item_id}': {error}")))?
    else {
        return Ok(None);
    };
    let refs = query_as::<_, ExternalRefRow>(SELECT_REFS)
        .bind(item_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board refs '{item_id}': {error}")))?;
    item_from_rows(row, refs).map(Some)
}

pub(super) async fn bump_change_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    scope: &str,
) -> Result<i64, CliError> {
    query("UPDATE change_tracking_state SET last_seq = last_seq + 1 WHERE singleton = 1")
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("advance task board change sequence: {error}")))?;
    let change_seq =
        query_scalar::<_, i64>("SELECT last_seq FROM change_tracking_state WHERE singleton = 1")
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("read task board change sequence: {error}")))?;
    query(
        "INSERT INTO change_tracking (scope, version, updated_at, change_seq)
        VALUES (?1, 1, ?2, ?3)
        ON CONFLICT(scope) DO UPDATE SET version = version + 1,
        updated_at = excluded.updated_at, change_seq = excluded.change_seq",
    )
    .bind(scope)
    .bind(utc_now())
    .bind(change_seq)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record task board change: {error}")))?;
    Ok(change_seq)
}

pub(super) async fn items_change_sequence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<i64, CliError> {
    query_scalar("SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = ?1")
        .bind(ITEMS_CHANGE_SCOPE)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "read task-board item sequence in transaction: {error}"
            ))
        })
        .map(|sequence| sequence.unwrap_or(0))
}

pub(super) fn validate_item(item: &TaskBoardItem) -> Result<(), CliError> {
    io::validate_safe_segment(&item.id)?;
    if item.schema_version != CURRENT_TASK_BOARD_ITEM_VERSION {
        return Err(CliErrorKind::workflow_version(format!(
            "task-board item '{}' uses unsupported schema v{}",
            item.id, item.schema_version
        ))
        .into());
    }
    if item.title.trim().is_empty() {
        return Err(db_error(format!(
            "task-board item '{}' must have a non-blank title",
            item.id
        )));
    }
    if item
        .estimated_tokens
        .is_some_and(|value| !(1..=MAX_TASK_BOARD_ESTIMATE).contains(&value))
    {
        return Err(db_error("task-board estimated tokens are out of range"));
    }
    if item
        .estimated_cost_microusd
        .is_some_and(|value| !(1..=MAX_TASK_BOARD_ESTIMATE).contains(&value))
    {
        return Err(db_error("task-board estimated cost is out of range"));
    }
    if item.parent_item_id.as_deref() == Some(item.id.as_str()) {
        return Err(db_error(format!(
            "task-board item '{}' cannot be its own parent",
            item.id
        )));
    }
    validate_lane_placement(item).map_err(db_error)?;
    Ok(())
}
