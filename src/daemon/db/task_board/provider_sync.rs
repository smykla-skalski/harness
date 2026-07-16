use chrono::{DateTime, Duration};
use serde::de::DeserializeOwned;
use sqlx::{SqliteConnection, query, query_as};

use crate::daemon::db::task_board::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::external::ExternalProviderScopeState;
use crate::task_board::{ExternalProvider, ExternalRefProvider, TaskBoardSyncConflict};

use super::ORCHESTRATOR_CHANGE_SCOPE;

const BACKOFF_BASE_SECONDS: u64 = 30;
const BACKOFF_MULTIPLIER: u64 = 4;
const BACKOFF_MAX_SECONDS: u64 = 600;

impl AsyncDaemonDb {
    pub(crate) async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        query_as::<_, (Option<String>, i64, Option<String>)>(
            "SELECT base_revision, failure_count, backoff_until
             FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("read task-board provider scope: {error}")))?
        .map_or_else(
            || Ok(ExternalProviderScopeState::default()),
            |(base_revision, failure_count, backoff_until)| {
                Ok(ExternalProviderScopeState {
                    base_revision,
                    failure_count: u32::try_from(failure_count).map_err(|error| {
                        db_error(format!("decode task-board provider failure count: {error}"))
                    })?,
                    backoff_until,
                })
            },
        )
    }

    pub(crate) async fn record_task_board_provider_scope_success(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        base_revision: Option<&str>,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board provider scope success")
            .await?;
        let changed = query(
            "INSERT INTO task_board_provider_scope_state (
                provider, scope_id, base_revision, health, failure_count, backoff_until, updated_at
             ) VALUES (?1, ?2, ?3, 'healthy', 0, NULL, ?4)
             ON CONFLICT(provider, scope_id) DO UPDATE SET
                base_revision = COALESCE(
                    excluded.base_revision,
                    task_board_provider_scope_state.base_revision
                ),
                health = 'healthy',
                failure_count = 0,
                backoff_until = NULL,
                updated_at = excluded.updated_at
             WHERE task_board_provider_scope_state.health IS NOT 'healthy'
                OR task_board_provider_scope_state.failure_count IS NOT 0
                OR task_board_provider_scope_state.backoff_until IS NOT NULL
                OR (excluded.base_revision IS NOT NULL
                    AND task_board_provider_scope_state.base_revision
                        IS NOT excluded.base_revision)",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .bind(base_revision)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record task-board provider success: {error}")))?
        .rows_affected()
            > 0;
        if changed {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board provider success: {error}")))?;
        Ok(())
    }

    pub(crate) async fn record_task_board_provider_scope_failure(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board provider scope failure")
            .await?;
        let (base_revision, failure_count) = query_as::<_, (Option<String>, i64)>(
            "SELECT base_revision, failure_count FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board provider failure count: {error}")))?
        .map_or((None, 1_u32), |(base_revision, count)| {
            (
                base_revision,
                u32::try_from(count).unwrap_or(u32::MAX).saturating_add(1),
            )
        });
        let now = utc_now();
        let backoff_until = backoff_deadline(&now, failure_count)?;
        query(
            "INSERT INTO task_board_provider_scope_state (
                provider, scope_id, health, failure_count, backoff_until, updated_at
             ) VALUES (?1, ?2, 'backing_off', ?3, ?4, ?5)
             ON CONFLICT(provider, scope_id) DO UPDATE SET
                health = 'backing_off',
                failure_count = excluded.failure_count,
                backoff_until = excluded.backoff_until,
                updated_at = excluded.updated_at",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .bind(i64::from(failure_count))
        .bind(&backoff_until)
        .bind(now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record task-board provider failure: {error}")))?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board provider failure: {error}")))?;
        Ok(ExternalProviderScopeState {
            base_revision,
            failure_count,
            backoff_until: Some(backoff_until),
        })
    }

    pub(crate) async fn replace_open_task_board_sync_conflicts(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        external_ref: &str,
        conflicts: &[TaskBoardSyncConflict],
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board sync conflict replace")
            .await?;
        let mut changed = supersede_removed_conflicts(
            transaction.as_mut(),
            item_id,
            provider,
            external_ref,
            conflicts,
        )
        .await?;
        for conflict in conflicts {
            changed |= upsert_open_conflict(transaction.as_mut(), conflict).await?;
        }
        if changed {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board sync conflicts: {error}")))
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

async fn supersede_removed_conflicts(
    connection: &mut SqliteConnection,
    item_id: &str,
    provider: ExternalProvider,
    external_ref: &str,
    conflicts: &[TaskBoardSyncConflict],
) -> Result<bool, CliError> {
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
    let mut changed = false;
    for (conflict_id, field) in rows {
        if !fields.contains(&field.as_str()) {
            changed |= query(
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
        }
    }
    Ok(changed)
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
    let changed = query(
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
    .map_err(|error| db_error(format!("insert task-board sync conflict: {error}")))?
    .rows_affected()
        > 0;
    Ok(changed)
}

fn backoff_deadline(now: &str, failure_count: u32) -> Result<String, CliError> {
    let now = DateTime::parse_from_rfc3339(now)
        .map_err(|error| db_error(format!("parse provider scope timestamp: {error}")))?;
    let exponent = failure_count.saturating_sub(1).min(10);
    let multiplier = BACKOFF_MULTIPLIER.saturating_pow(exponent);
    let seconds = BACKOFF_BASE_SECONDS
        .saturating_mul(multiplier)
        .min(BACKOFF_MAX_SECONDS);
    let seconds = i64::try_from(seconds).unwrap_or(i64::MAX);
    Ok((now + Duration::seconds(seconds))
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string())
}

fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
        ExternalProvider::Todoist => "todoist",
    }
}

fn ref_provider_label(provider: ExternalRefProvider) -> &'static str {
    match provider {
        ExternalRefProvider::GitHub => "github",
        ExternalRefProvider::Todoist => "todoist",
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
