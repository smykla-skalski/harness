use serde::de::DeserializeOwned;
use sqlx::{SqliteConnection, query, query_as};

use crate::daemon::db::task_board::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncField, TaskBoardSyncConflict,
};

use super::ORCHESTRATOR_CHANGE_SCOPE;

#[derive(Debug, Default)]
pub(super) struct SyncConflictReplacement {
    changed_fields: Vec<String>,
}

impl SyncConflictReplacement {
    pub(super) fn changed(&self) -> bool {
        !self.changed_fields.is_empty()
    }

    pub(super) fn changed_fields(&self) -> &[String] {
        &self.changed_fields
    }

    fn record_changed_field(&mut self, field: &str) {
        if !self.changed_fields.iter().any(|changed| changed == field) {
            self.changed_fields.push(field.to_owned());
            self.changed_fields.sort_unstable();
        }
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn replace_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board sync conflict replace")
            .await?;
        let replacement = replace_open_sync_conflicts_in_connection(
            transaction.as_mut(),
            item_id,
            provider,
            external_ref,
            item_revision,
            conflicts,
        )
        .await?;
        if replacement.changed() {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board sync conflicts: {error}")))
    }

    pub(crate) async fn supersede_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        item_revision: i64,
        resolved_fields: &[ExternalSyncField],
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board sync conflict supersession")
            .await?;
        let resolved_at = utc_now();
        let changed = supersede_open_sync_conflicts_in_connection(
            transaction.as_mut(),
            item_id,
            provider,
            external_ref,
            item_revision,
            resolved_fields,
            &resolved_at,
        )
        .await?;
        if changed {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit sync conflict supersession: {error}")))
    }

    #[cfg(test)]
    pub(crate) async fn open_task_board_sync_conflicts(
        &self,
    ) -> Result<Vec<TaskBoardSyncConflict>, CliError> {
        let rows = query_as::<_, ConflictRow>(
            "SELECT conflict_id, item_id, provider, external_ref, field,
                    base_value_json, local_value_json, remote_value_json,
                    item_revision, provider_revision, state
             FROM task_board_sync_conflicts WHERE state = 'open'
             ORDER BY conflict_id",
        )
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list task-board sync conflicts: {error}")))?;
        rows.into_iter().map(ConflictRow::into_conflict).collect()
    }
}

pub(super) async fn replace_open_sync_conflicts_in_connection(
    connection: &mut SqliteConnection,
    item_id: &str,
    provider: ExternalProvider,
    external_ref: &str,
    item_revision: i64,
    conflicts: &[TaskBoardSyncConflict],
) -> Result<SyncConflictReplacement, CliError> {
    require_conflict_scope(item_id, provider, external_ref, item_revision, conflicts)?;
    require_item_revision(connection, item_id, item_revision).await?;
    let mut replacement =
        supersede_removed_conflicts(connection, item_id, provider, external_ref, conflicts).await?;
    for conflict in conflicts {
        if upsert_open_conflict(connection, conflict).await? {
            replacement.record_changed_field(&conflict.field);
        }
    }
    Ok(replacement)
}

pub(super) async fn supersede_open_sync_conflicts_in_connection(
    connection: &mut SqliteConnection,
    item_id: &str,
    provider: ExternalProvider,
    external_ref: &str,
    item_revision: i64,
    resolved_fields: &[ExternalSyncField],
    resolved_at: &str,
) -> Result<bool, CliError> {
    require_item_revision(connection, item_id, item_revision).await?;
    let mut changed = false;
    for field in resolved_fields {
        changed |= query(
            "UPDATE task_board_sync_conflicts
             SET state = 'superseded', resolved_at = ?5
             WHERE item_id = ?1 AND provider = ?2 AND external_ref = ?3
               AND field = ?4 AND state = 'open'",
        )
        .bind(item_id)
        .bind(provider_label(provider))
        .bind(external_ref)
        .bind(field_label(*field))
        .bind(resolved_at)
        .execute(&mut *connection)
        .await
        .map_err(|error| db_error(format!("supersede task-board sync field: {error}")))?
        .rows_affected()
            > 0;
    }
    Ok(changed)
}

fn require_conflict_scope(
    item_id: &str,
    provider: ExternalProvider,
    external_ref: &str,
    expected_revision: i64,
    conflicts: &[TaskBoardSyncConflict],
) -> Result<(), CliError> {
    let matches_scope = conflicts.iter().all(|conflict| {
        conflict.item_id == item_id
            && ExternalProvider::from(conflict.provider) == provider
            && conflict.external_ref == external_ref
            && conflict.item_revision == expected_revision
    });
    if matches_scope {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board sync conflicts for '{item_id}' do not match the provider scope or item revision {expected_revision}"
    ))
    .into())
}

async fn require_item_revision(
    connection: &mut SqliteConnection,
    item_id: &str,
    expected_revision: i64,
) -> Result<(), CliError> {
    let current = query_as::<_, (i64,)>("SELECT revision FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_optional(&mut *connection)
        .await
        .map_err(|error| db_error(format!("read task-board conflict item revision: {error}")))?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
    if current.0 == expected_revision {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(format!(
        "task-board item '{item_id}' changed before sync conflict persistence"
    ))
    .into())
}

async fn supersede_removed_conflicts(
    connection: &mut SqliteConnection,
    item_id: &str,
    provider: ExternalProvider,
    external_ref: &str,
    conflicts: &[TaskBoardSyncConflict],
) -> Result<SyncConflictReplacement, CliError> {
    let fields = conflicts
        .iter()
        .map(|conflict| conflict.field.as_str())
        .collect::<Vec<_>>();
    let rows = query_as::<_, (String, String)>(
        "SELECT conflict_id, field FROM task_board_sync_conflicts
         WHERE item_id = ?1 AND provider = ?2 AND external_ref = ?3 AND state = 'open'",
    )
    .bind(item_id)
    .bind(provider_label(provider))
    .bind(external_ref)
    .fetch_all(&mut *connection)
    .await
    .map_err(|error| db_error(format!("read open task-board sync conflicts: {error}")))?;
    let mut replacement = SyncConflictReplacement::default();
    for (conflict_id, field) in rows {
        if !fields.contains(&field.as_str()) {
            let changed = query(
                "UPDATE task_board_sync_conflicts
                 SET state = 'superseded', resolved_at = ?2
                 WHERE conflict_id = ?1",
            )
            .bind(conflict_id)
            .bind(utc_now())
            .execute(&mut *connection)
            .await
            .map_err(|error| db_error(format!("supersede task-board sync conflict: {error}")))?
            .rows_affected()
                > 0;
            if changed {
                replacement.record_changed_field(&field);
            }
        }
    }
    Ok(replacement)
}

async fn upsert_open_conflict(
    connection: &mut SqliteConnection,
    conflict: &TaskBoardSyncConflict,
) -> Result<bool, CliError> {
    let base_value_json = to_json(&conflict.base_value)?;
    let local_value_json = to_json(&conflict.local_value)?;
    let remote_value_json = to_json(&conflict.remote_value)?;
    let updated = query(
        "UPDATE task_board_sync_conflicts SET
            base_value_json = ?6, local_value_json = ?7,
            remote_value_json = ?8, item_revision = ?9, provider_revision = ?10
         WHERE item_id = ?2 AND provider = ?3 AND external_ref = ?4
           AND field = ?5 AND state = 'open'
           AND (base_value_json IS NOT ?6 OR local_value_json IS NOT ?7
                OR remote_value_json IS NOT ?8 OR item_revision IS NOT ?9
                OR provider_revision IS NOT ?10)",
    )
    .bind(&conflict.conflict_id)
    .bind(&conflict.item_id)
    .bind(ref_provider_label(conflict.provider))
    .bind(&conflict.external_ref)
    .bind(&conflict.field)
    .bind(&base_value_json)
    .bind(&local_value_json)
    .bind(&remote_value_json)
    .bind(conflict.item_revision)
    .bind(&conflict.provider_revision)
    .execute(&mut *connection)
    .await
    .map_err(|error| db_error(format!("update task-board sync conflict: {error}")))?;
    if updated.rows_affected() > 0 {
        return Ok(true);
    }
    let open_exists = query_as::<_, (i64,)>(
        "SELECT EXISTS(
            SELECT 1 FROM task_board_sync_conflicts
            WHERE item_id = ?1 AND provider = ?2 AND external_ref = ?3
              AND field = ?4 AND state = 'open'
         )",
    )
    .bind(&conflict.item_id)
    .bind(ref_provider_label(conflict.provider))
    .bind(&conflict.external_ref)
    .bind(&conflict.field)
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| db_error(format!("read task-board sync conflict identity: {error}")))?
    .0 != 0;
    if open_exists {
        return Ok(false);
    }
    insert_open_conflict(
        connection,
        conflict,
        base_value_json,
        local_value_json,
        remote_value_json,
    )
    .await
}

async fn insert_open_conflict(
    connection: &mut SqliteConnection,
    conflict: &TaskBoardSyncConflict,
    base_value_json: String,
    local_value_json: String,
    remote_value_json: String,
) -> Result<bool, CliError> {
    query(
        "INSERT INTO task_board_sync_conflicts (
            conflict_id, item_id, provider, external_ref, field,
            base_value_json, local_value_json, remote_value_json,
            item_revision, provider_revision, state, detected_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'open', ?11)
         ON CONFLICT(conflict_id) DO UPDATE SET
            base_value_json = excluded.base_value_json,
            local_value_json = excluded.local_value_json,
            remote_value_json = excluded.remote_value_json,
            item_revision = excluded.item_revision,
            provider_revision = excluded.provider_revision,
            state = 'open', detected_at = excluded.detected_at,
            resolved_at = NULL, resolved_by = NULL",
    )
    .bind(&conflict.conflict_id)
    .bind(&conflict.item_id)
    .bind(ref_provider_label(conflict.provider))
    .bind(&conflict.external_ref)
    .bind(&conflict.field)
    .bind(base_value_json)
    .bind(local_value_json)
    .bind(remote_value_json)
    .bind(conflict.item_revision)
    .bind(&conflict.provider_revision)
    .bind(utc_now())
    .execute(&mut *connection)
    .await
    .map_err(|error| db_error(format!("insert task-board sync conflict: {error}")))
    .map(|result| result.rows_affected() > 0)
}

const fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
        ExternalProvider::Todoist => "todoist",
    }
}

const fn ref_provider_label(provider: ExternalRefProvider) -> &'static str {
    match provider {
        ExternalRefProvider::GitHub => "github",
        ExternalRefProvider::Todoist => "todoist",
    }
}

const fn field_label(field: ExternalSyncField) -> &'static str {
    match field {
        ExternalSyncField::Title => "title",
        ExternalSyncField::Body => "body",
        ExternalSyncField::Status => "status",
        ExternalSyncField::Project => "project",
        ExternalSyncField::Url => "url",
    }
}

fn to_json(value: &serde_json::Value) -> Result<String, CliError> {
    serde_json::to_string(value)
        .map_err(|error| db_error(format!("serialize task-board sync conflict value: {error}")))
}

fn from_json<T: DeserializeOwned>(value: &str) -> Result<T, CliError> {
    serde_json::from_str(value)
        .map_err(|error| db_error(format!("parse task-board sync conflict value: {error}")))
}

#[derive(sqlx::FromRow)]
struct ConflictRow {
    conflict_id: String,
    item_id: String,
    provider: String,
    external_ref: String,
    field: String,
    base_value_json: String,
    local_value_json: String,
    remote_value_json: String,
    item_revision: i64,
    provider_revision: Option<String>,
    state: String,
}

impl ConflictRow {
    fn into_conflict(self) -> Result<TaskBoardSyncConflict, CliError> {
        Ok(TaskBoardSyncConflict {
            conflict_id: self.conflict_id,
            item_id: self.item_id,
            provider: from_json(&format!("\"{}\"", self.provider))?,
            external_ref: self.external_ref,
            field: self.field,
            base_value: from_json(&self.base_value_json)?,
            local_value: from_json(&self.local_value_json)?,
            remote_value: from_json(&self.remote_value_json)?,
            item_revision: self.item_revision,
            provider_revision: self.provider_revision,
            state: from_json(&format!("\"{}\"", self.state))?,
        })
    }
}
