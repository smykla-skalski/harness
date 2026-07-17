use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ITEMS_CHANGE_SCOPE;
use super::mapper::{item_from_rows, label, to_json};
use super::rows::{ExternalRefRow, ItemRow};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::errors::CliErrorKind;
use crate::infra::io;
use crate::task_board::types::{CURRENT_TASK_BOARD_ITEM_VERSION, MAX_TASK_BOARD_ESTIMATE};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

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
    pub(crate) async fn create_task_board_item(
        &self,
        mut item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        let mut transaction = self
            .begin_immediate_transaction("task board item create")
            .await?;
        if load_item_in_tx(&mut transaction, &item.id).await?.is_some() {
            return Err(db_error(format!(
                "task-board item '{}' already exists",
                item.id
            )));
        }
        insert_item_in_tx(&mut transaction, &item, 1).await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item create: {error}")))?;
        Ok(TaskBoardMutation {
            item,
            item_revision: 1,
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

    /// List Task Board items including tombstones.
    pub(crate) async fn list_task_board_items_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board item list: {error}")))?;
        let rows = query_as::<_, ItemRow>("SELECT * FROM task_board_items")
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("list task board items: {error}")))?;
        let refs = query_as::<_, ExternalRefRow>(
            "SELECT item_id, position, provider,
            external_id, url, sync_state_json FROM task_board_external_refs
            ORDER BY item_id, position",
        )
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("list task board external refs: {error}")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item list: {error}")))?;
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
            items.push(item_from_rows(row, refs)?.0);
        }
        sort_items(&mut items);
        Ok(items)
    }

    /// Atomically load and conditionally mutate one Task Board item.
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
        validate_item(&item)?;
        item.status = item.status.canonical_persisted_status();
        item.updated_at = utc_now();
        replace_item_in_tx(&mut transaction, &item, revision + 1).await?;
        let change_revision = bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board item update: {error}")))?;
        Ok(Some(TaskBoardMutation {
            item,
            item_revision: revision + 1,
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

pub(super) async fn insert_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    revision: i64,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_items (
        item_id, schema_version, title, body, status, priority, tags_json, project_id,
        target_project_types_json, agent_mode, workflow_kind, execution_repository,
        estimated_tokens, estimated_cost_microusd, imported_from_provider, planning_json,
        workflow_json, session_id, work_item_id, usage_json, created_at, updated_at,
        deleted_at, revision
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
        ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)",
    )
    .bind(&item.id)
    .bind(i64::from(item.schema_version))
    .bind(&item.title)
    .bind(&item.body)
    .bind(label(item.status, "task board status")?)
    .bind(label(item.priority, "task board priority")?)
    .bind(to_json(&item.tags, "task board tags")?)
    .bind(&item.project_id)
    .bind(to_json(
        &item.target_project_types,
        "task board project types",
    )?)
    .bind(label(item.agent_mode, "task board agent mode")?)
    .bind(label(item.workflow_kind, "task board workflow kind")?)
    .bind(&item.execution_repository)
    .bind(optional_u64_as_i64(
        item.estimated_tokens,
        "task board estimated tokens",
    )?)
    .bind(optional_u64_as_i64(
        item.estimated_cost_microusd,
        "task board estimated cost",
    )?)
    .bind(
        item.imported_from_provider
            .map(|provider| label(provider, "task board imported provider"))
            .transpose()?,
    )
    .bind(to_json(&item.planning, "task board planning state")?)
    .bind(to_json(&item.workflow, "task board workflow state")?)
    .bind(&item.session_id)
    .bind(&item.work_item_id)
    .bind(to_json(&item.usage, "task board usage")?)
    .bind(&item.created_at)
    .bind(&item.updated_at)
    .bind(&item.deleted_at)
    .bind(revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board item '{}': {error}", item.id)))?;
    insert_refs(transaction, item).await
}

pub(super) async fn replace_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    revision: i64,
) -> Result<(), CliError> {
    validate_item(item)?;
    query(
        "UPDATE task_board_items SET
        schema_version = ?2, title = ?3, body = ?4, status = ?5, priority = ?6,
        tags_json = ?7, project_id = ?8, target_project_types_json = ?9,
        agent_mode = ?10, workflow_kind = ?11, execution_repository = ?12,
        estimated_tokens = ?13, estimated_cost_microusd = ?14,
        imported_from_provider = ?15, planning_json = ?16, workflow_json = ?17,
        session_id = ?18, work_item_id = ?19, usage_json = ?20, created_at = ?21,
        updated_at = ?22, deleted_at = ?23, revision = ?24
        WHERE item_id = ?1",
    )
    .bind(&item.id)
    .bind(i64::from(item.schema_version))
    .bind(&item.title)
    .bind(&item.body)
    .bind(label(item.status, "task board status")?)
    .bind(label(item.priority, "task board priority")?)
    .bind(to_json(&item.tags, "task board tags")?)
    .bind(&item.project_id)
    .bind(to_json(
        &item.target_project_types,
        "task board project types",
    )?)
    .bind(label(item.agent_mode, "task board agent mode")?)
    .bind(label(item.workflow_kind, "task board workflow kind")?)
    .bind(&item.execution_repository)
    .bind(optional_u64_as_i64(
        item.estimated_tokens,
        "task board estimated tokens",
    )?)
    .bind(optional_u64_as_i64(
        item.estimated_cost_microusd,
        "task board estimated cost",
    )?)
    .bind(
        item.imported_from_provider
            .map(|provider| label(provider, "task board imported provider"))
            .transpose()?,
    )
    .bind(to_json(&item.planning, "task board planning state")?)
    .bind(to_json(&item.workflow, "task board workflow state")?)
    .bind(&item.session_id)
    .bind(&item.work_item_id)
    .bind(to_json(&item.usage, "task board usage")?)
    .bind(&item.created_at)
    .bind(&item.updated_at)
    .bind(&item.deleted_at)
    .bind(revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("replace task board item '{}': {error}", item.id)))?;
    query("DELETE FROM task_board_external_refs WHERE item_id = ?1")
        .bind(&item.id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear task board refs '{}': {error}", item.id)))?;
    insert_refs(transaction, item).await
}

async fn insert_refs(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
) -> Result<(), CliError> {
    for (position, reference) in item.external_refs.iter().enumerate() {
        query(
            "INSERT INTO task_board_external_refs (
            item_id, position, provider, external_id, url, sync_state_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(&item.id)
        .bind(i64::try_from(position).unwrap_or(i64::MAX))
        .bind(label(reference.provider, "task board external provider")?)
        .bind(&reference.external_id)
        .bind(&reference.url)
        .bind(
            reference
                .sync_state
                .as_ref()
                .map(|state| to_json(state, "task board external sync state"))
                .transpose()?,
        )
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert task board refs '{}': {error}", item.id)))?;
    }
    Ok(())
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

fn validate_item(item: &TaskBoardItem) -> Result<(), CliError> {
    io::validate_safe_segment(&item.id)?;
    if item.schema_version != CURRENT_TASK_BOARD_ITEM_VERSION {
        return Err(CliErrorKind::workflow_version(format!(
            "task-board item '{}' uses unsupported schema v{}",
            item.id, item.schema_version
        ))
        .into());
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
    Ok(())
}

fn optional_u64_as_i64(value: Option<u64>, context: &str) -> Result<Option<i64>, CliError> {
    value
        .map(|value| {
            i64::try_from(value).map_err(|error| db_error(format!("store {context}: {error}")))
        })
        .transpose()
}

fn sort_items(items: &mut [TaskBoardItem]) {
    items.sort_by(|left, right| {
        left.status
            .cmp(&right.status)
            .then_with(|| right.priority.cmp(&left.priority))
            .then_with(|| left.created_at.cmp(&right.created_at))
            .then_with(|| left.id.cmp(&right.id))
    });
}
