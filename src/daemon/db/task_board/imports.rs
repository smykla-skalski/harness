use std::path::Path;

use serde::Serialize;
use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::aggregates::upsert_machine_in_tx;
use super::items::{bump_change_in_tx, insert_item_in_tx};
use super::mapper::to_json;
use super::{
    ITEMS_CHANGE_SCOPE, MACHINES_CHANGE_SCOPE, ORCHESTRATOR_CHANGE_SCOPE,
    POLICY_RUNTIME_CHANGE_SCOPE, RUNTIME_CONFIG_CHANGE_SCOPE,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::TaskBoardGitRuntimeConfig;
use crate::task_board::legacy_import::LegacyTaskBoardSnapshot;

pub(crate) const LEGACY_GLOBAL_SOURCE: &str = "legacy_global_board";
pub(crate) const EMPTY_DATABASE_SOURCE: &str = "empty_database";

#[derive(Debug)]
pub(crate) struct TaskBoardImportResult {
    pub(crate) imported: bool,
    pub(crate) change_revision: i64,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct TaskBoardImportMarker {
    pub(crate) source_kind: String,
    pub(crate) source_digest: String,
    pub(crate) canonical_model_digest: String,
    pub(crate) source_counts_json: String,
    pub(crate) staged_path: Option<String>,
    pub(crate) imported_at: String,
    pub(crate) archived_at: Option<String>,
    pub(crate) archive_path: Option<String>,
    pub(crate) secret_handoff_id: Option<String>,
    pub(crate) secret_handoff_digest: Option<String>,
    pub(crate) secret_handoff_phase: String,
    pub(crate) secret_acknowledged_at: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn import_legacy_task_board(
        &self,
        snapshot: &LegacyTaskBoardSnapshot,
        staged_path: Option<&Path>,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError> {
        self.import_task_board_snapshot(
            LEGACY_GLOBAL_SOURCE,
            snapshot,
            staged_path,
            runtime_config,
            secret_handoff_digest,
        )
        .await
    }

    pub(crate) async fn initialize_empty_task_board(
        &self,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError> {
        let snapshot = LegacyTaskBoardSnapshot::empty()?;
        self.import_task_board_snapshot(
            EMPTY_DATABASE_SOURCE,
            &snapshot,
            None,
            runtime_config,
            secret_handoff_digest,
        )
        .await
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "legacy import must verify and record all source state in one transaction"
    )]
    async fn import_task_board_snapshot(
        &self,
        source_kind: &str,
        snapshot: &LegacyTaskBoardSnapshot,
        staged_path: Option<&Path>,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("legacy task board import")
            .await?;
        if let Some(marker) = load_marker_in_tx(&mut transaction, source_kind).await? {
            verify_existing_marker(&marker, snapshot)?;
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit existing task board import: {error}")))?;
            return Ok(TaskBoardImportResult {
                imported: false,
                change_revision: self.task_board_revision().await?,
            });
        }
        ensure_import_target_empty(&mut transaction).await?;
        insert_snapshot(&mut transaction, snapshot, runtime_config).await?;
        verify_snapshot(&mut transaction, snapshot, runtime_config).await?;
        let counts_json = to_json(&snapshot.counts(), "legacy task board counts")?;
        let imported_at = utc_now();
        let secret_handoff_phase = if secret_handoff_digest.is_some() {
            "pending"
        } else {
            "complete"
        };
        let secret_handoff_id =
            secret_handoff_digest.map(|_| format!("task-board-secret-{}", Uuid::new_v4().simple()));
        query(
            "INSERT INTO task_board_imports (
            source_kind, source_digest, canonical_model_digest, source_counts_json,
            staged_path, imported_at, archived_at, archive_path, secret_handoff_id,
            secret_handoff_digest, secret_handoff_phase, secret_acknowledged_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, ?7, ?8, ?9, NULL)",
        )
        .bind(source_kind)
        .bind(&snapshot.source_digest)
        .bind(&snapshot.canonical_digest)
        .bind(counts_json)
        .bind(staged_path.map(|path| path.to_string_lossy().into_owned()))
        .bind(imported_at)
        .bind(secret_handoff_id)
        .bind(secret_handoff_digest)
        .bind(secret_handoff_phase)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record task board import marker: {error}")))?;
        let mut change_revision = 0;
        for scope in [
            ITEMS_CHANGE_SCOPE,
            MACHINES_CHANGE_SCOPE,
            ORCHESTRATOR_CHANGE_SCOPE,
            RUNTIME_CONFIG_CHANGE_SCOPE,
            POLICY_RUNTIME_CHANGE_SCOPE,
        ] {
            change_revision = bump_change_in_tx(&mut transaction, scope).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit legacy task board import: {error}")))?;
        Ok(TaskBoardImportResult {
            imported: true,
            change_revision,
        })
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "legacy snapshot insertion preserves one atomic transaction across aggregates"
)]
async fn insert_snapshot(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
    runtime_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    for item in &snapshot.items {
        insert_item_in_tx(transaction, item, 1).await?;
    }
    for machine in &snapshot.machines {
        upsert_machine_in_tx(transaction, machine).await?;
    }
    if let Some(machine_id) = &snapshot.local_machine_id {
        query("INSERT INTO task_board_local_machine (singleton, machine_id) VALUES (1, ?1)")
            .bind(machine_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("import local machine pointer: {error}")))?;
    }
    insert_singletons(transaction, snapshot, runtime_config).await?;
    insert_policy_runtime(transaction, snapshot).await
}

async fn insert_singletons(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
    runtime_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_orchestrator_settings (
        singleton, settings_json, revision, updated_at
    ) VALUES (1, ?1, 1, ?2)",
    )
    .bind(to_json(&snapshot.settings, "orchestrator settings")?)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("import orchestrator settings: {error}")))?;
    query(
        "INSERT INTO task_board_orchestrator_state (
        singleton, state_json, enabled, running, revision, updated_at
    ) VALUES (1, ?1, ?2, ?3, 1, ?4)",
    )
    .bind(to_json(&snapshot.state, "orchestrator state")?)
    .bind(snapshot.state.enabled)
    .bind(snapshot.state.running)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("import orchestrator state: {error}")))?;
    let runtime_config = runtime_config.without_secret_metadata();
    query(
        "INSERT INTO task_board_runtime_config (
        singleton, config_json, revision, updated_at
    ) VALUES (1, ?1, 1, ?2)",
    )
    .bind(to_json(&runtime_config, "task board runtime config")?)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("import task board runtime config: {error}")))?;
    Ok(())
}

async fn insert_policy_runtime(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    for (position, run) in snapshot.policy_runs.iter().enumerate() {
        query(
            "INSERT INTO policy_workflow_runs (
            run_id, position, workflow_id, subject_key, subject_fingerprint, trigger, status,
            waiting_since, created_at, updated_at, completed_at, payload_json, revision
        ) VALUES (?1, ?2, ?3, ?4, ?5, json_extract(?6, '$.trigger'),
            json_extract(?6, '$.status'), ?7, ?8, ?9, ?10, ?6, 1)",
        )
        .bind(&run.run_id)
        .bind(position_i64(position))
        .bind(&run.workflow_id)
        .bind(&run.subject.key)
        .bind(&run.subject_fingerprint)
        .bind(to_json(run, "policy workflow run")?)
        .bind(&run.waiting_since)
        .bind(&run.created_at)
        .bind(&run.updated_at)
        .bind(&run.completed_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("import policy run: {error}")))?;
    }
    insert_policy_events(transaction, snapshot).await?;
    insert_outbox(
        transaction,
        "policy_handoff_outbox",
        &snapshot.handoffs,
        |record| &record.recorded_at,
    )
    .await?;
    insert_outbox(
        transaction,
        "policy_notification_outbox",
        &snapshot.notifications,
        |record| &record.recorded_at,
    )
    .await?;
    insert_outbox(
        transaction,
        "policy_task_creation_outbox",
        &snapshot.task_creations,
        |record| &record.recorded_at,
    )
    .await
}

async fn insert_policy_events(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    for (position, event) in snapshot.policy_events.iter().enumerate() {
        query(
            "INSERT INTO policy_event_inbox (
            event_key, subject_key, position, occurred_at, payload_json
        ) VALUES (?1, ?2, ?3, ?4, ?5)",
        )
        .bind(&event.event_key)
        .bind(&event.subject_key)
        .bind(position_i64(position))
        .bind(&event.occurred_at)
        .bind(to_json(event, "policy event")?)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("import policy event: {error}")))?;
    }
    Ok(())
}

async fn insert_outbox<T: Serialize>(
    transaction: &mut Transaction<'_, Sqlite>,
    table: &'static str,
    records: &[T],
    recorded_at: impl Fn(&T) -> &str,
) -> Result<(), CliError> {
    let insert = match table {
        "policy_handoff_outbox" => {
            "INSERT INTO policy_handoff_outbox (recorded_at, payload_json) VALUES (?1, ?2)"
        }
        "policy_notification_outbox" => {
            "INSERT INTO policy_notification_outbox (recorded_at, payload_json) VALUES (?1, ?2)"
        }
        "policy_task_creation_outbox" => {
            "INSERT INTO policy_task_creation_outbox (recorded_at, payload_json) VALUES (?1, ?2)"
        }
        _ => return Err(db_error("unsupported policy outbox import table")),
    };
    for record in records {
        query(insert)
            .bind(recorded_at(record))
            .bind(to_json(record, "policy outbox record")?)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("import policy outbox record: {error}")))?;
    }
    Ok(())
}

async fn verify_snapshot(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
    runtime_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    for (table, expected) in [
        ("task_board_items", snapshot.items.len()),
        ("task_board_machines", snapshot.machines.len()),
        ("policy_workflow_runs", snapshot.policy_runs.len()),
        ("policy_event_inbox", snapshot.policy_events.len()),
        ("policy_handoff_outbox", snapshot.handoffs.len()),
        ("policy_notification_outbox", snapshot.notifications.len()),
        ("policy_task_creation_outbox", snapshot.task_creations.len()),
    ] {
        let actual = count_table(transaction, table).await?;
        if actual != expected {
            return Err(db_error(format!(
                "legacy task board verification failed for {table}: expected {expected}, found {actual}"
            )));
        }
    }
    verify_ids(transaction, snapshot).await?;
    verify_singleton_json(
        transaction,
        "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
        &snapshot.settings,
        "orchestrator settings",
    )
    .await?;
    verify_singleton_json(
        transaction,
        "SELECT state_json FROM task_board_orchestrator_state WHERE singleton = 1",
        &snapshot.state,
        "orchestrator state",
    )
    .await?;
    verify_singleton_json(
        transaction,
        "SELECT config_json FROM task_board_runtime_config WHERE singleton = 1",
        &runtime_config.without_secret_metadata(),
        "task board runtime config",
    )
    .await
}

async fn verify_ids(
    transaction: &mut Transaction<'_, Sqlite>,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    let item_ids =
        query_as::<_, (String,)>("SELECT item_id FROM task_board_items ORDER BY item_id")
            .fetch_all(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("verify task board ids: {error}")))?
            .into_iter()
            .map(|row| row.0)
            .collect::<Vec<_>>();
    let mut expected = snapshot
        .items
        .iter()
        .map(|item| item.id.clone())
        .collect::<Vec<_>>();
    expected.sort();
    if item_ids != expected {
        return Err(db_error("legacy task board item id verification failed"));
    }
    Ok(())
}

async fn verify_singleton_json<T: Serialize>(
    transaction: &mut Transaction<'_, Sqlite>,
    sql: &'static str,
    expected: &T,
    context: &str,
) -> Result<(), CliError> {
    let stored = query_as::<_, (String,)>(sql)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("verify {context}: {error}")))?;
    if stored.0 != to_json(expected, context)? {
        return Err(db_error(format!("legacy {context} verification failed")));
    }
    Ok(())
}

async fn ensure_import_target_empty(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(), CliError> {
    for table in [
        "task_board_items",
        "task_board_machines",
        "policy_workflow_runs",
        "policy_event_inbox",
        "policy_handoff_outbox",
        "policy_notification_outbox",
        "policy_task_creation_outbox",
    ] {
        if count_table(transaction, table).await? != 0 {
            return Err(db_error(format!(
                "cannot import legacy task board into non-empty table {table}"
            )));
        }
    }
    Ok(())
}

async fn count_table(
    transaction: &mut Transaction<'_, Sqlite>,
    table: &'static str,
) -> Result<usize, CliError> {
    let sql = match table {
        "task_board_items" => "SELECT COUNT(*) FROM task_board_items",
        "task_board_machines" => "SELECT COUNT(*) FROM task_board_machines",
        "policy_workflow_runs" => "SELECT COUNT(*) FROM policy_workflow_runs",
        "policy_event_inbox" => "SELECT COUNT(*) FROM policy_event_inbox",
        "policy_handoff_outbox" => "SELECT COUNT(*) FROM policy_handoff_outbox",
        "policy_notification_outbox" => "SELECT COUNT(*) FROM policy_notification_outbox",
        "policy_task_creation_outbox" => "SELECT COUNT(*) FROM policy_task_creation_outbox",
        _ => return Err(db_error("unsupported task board import table")),
    };
    let count = query_as::<_, (i64,)>(sql)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("count {table}: {error}")))?
        .0;
    usize::try_from(count).map_err(|error| db_error(format!("convert {table} count: {error}")))
}

async fn load_marker_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    source_kind: &str,
) -> Result<Option<TaskBoardImportMarker>, CliError> {
    query_as::<_, TaskBoardImportMarker>(
        "SELECT * FROM task_board_imports
        WHERE source_kind = ?1",
    )
    .bind(source_kind)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board import marker: {error}")))
}

fn verify_existing_marker(
    marker: &TaskBoardImportMarker,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    if marker.source_digest == snapshot.source_digest
        && marker.canonical_model_digest == snapshot.canonical_digest
    {
        return Ok(());
    }
    Err(db_error(
        "legacy Task Board source changed after the database import completed",
    ))
}

fn position_i64(position: usize) -> i64 {
    i64::try_from(position).unwrap_or(i64::MAX)
}
