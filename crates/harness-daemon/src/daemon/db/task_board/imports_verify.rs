use super::{
    CliError, EMPTY_DATABASE_SOURCE, LegacyTaskBoardSnapshot, Serialize, Sqlite,
    TaskBoardGitRuntimeConfig, TaskBoardImportMarker, Transaction, db_error, query_as, to_json,
};

pub(super) async fn verify_snapshot(
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

pub(super) async fn ensure_import_target_empty(
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

pub(super) async fn load_marker_in_tx(
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

pub(super) fn verify_existing_marker(
    marker: &TaskBoardImportMarker,
    snapshot: &LegacyTaskBoardSnapshot,
) -> Result<(), CliError> {
    if marker.source_digest != snapshot.source_digest {
        return Err(db_error(
            "legacy Task Board source changed after the database import completed",
        ));
    }
    if marker.source_kind == EMPTY_DATABASE_SOURCE
        || marker.canonical_model_digest == snapshot.canonical_digest
    {
        return Ok(());
    }
    Err(db_error(
        "legacy Task Board source changed after the database import completed",
    ))
}
