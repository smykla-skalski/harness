use rusqlite::{Connection, Transaction};
use serde_json::Value;

use super::CliError;

const MIGRATION_SQL: &str = include_str!("migrations/0055_daemon_v56_task_board_inbox.sql");
const STATUS_KEYS: &[&str] = &[
    "status",
    "board_status",
    "from_status",
    "to_status",
    "dispatch_status_filter",
];

struct JsonColumn {
    table: &'static str,
    id: &'static str,
    column: &'static str,
    filter: Option<&'static str>,
}

const JSON_COLUMNS: &[JsonColumn] = &[
    JsonColumn {
        table: "task_board_orchestrator_settings",
        id: "singleton",
        column: "settings_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_orchestrator_state",
        id: "singleton",
        column: "state_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_orchestrator_runs",
        id: "run_id",
        column: "scope_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_orchestrator_runs",
        id: "run_id",
        column: "stage_summary_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_dispatch_intents",
        id: "intent_id",
        column: "payload_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_external_create_intents",
        id: "intent_id",
        column: "create_snapshot_json",
        filter: None,
    },
    JsonColumn {
        table: "task_board_external_create_intents",
        id: "intent_id",
        column: "external_ref_json",
        filter: None,
    },
    JsonColumn {
        table: "audit_events",
        id: "id",
        column: "payload_json",
        filter: Some("kind LIKE 'task_board.%'"),
    },
];

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| super::db_error(format!("begin schema v56 inbox migration: {error}")))?;
    transaction
        .execute_batch(MIGRATION_SQL)
        .map_err(|error| super::db_error(format!("apply schema v56 inbox migration: {error}")))?;
    rewrite_json_statuses(&transaction)?;
    transaction
        .commit()
        .map_err(|error| super::db_error(format!("commit schema v56 inbox migration: {error}")))
}

fn rewrite_json_statuses(transaction: &Transaction<'_>) -> Result<(), CliError> {
    for column in JSON_COLUMNS {
        let rows = load_json_rows(transaction, column)?;
        for (id, raw) in rows {
            let mut value = serde_json::from_str::<Value>(&raw).map_err(|error| {
                super::db_error(format!(
                    "parse {}.{} during schema v56 inbox migration: {error}",
                    column.table, column.column
                ))
            })?;
            if !rewrite_status_values(&mut value) {
                continue;
            }
            let canonical = serde_json::to_string(&value).map_err(|error| {
                super::db_error(format!(
                    "serialize {}.{} during schema v56 inbox migration: {error}",
                    column.table, column.column
                ))
            })?;
            let update = format!(
                "UPDATE {} SET {} = ?1 WHERE {} = ?2",
                column.table, column.column, column.id
            );
            transaction
                .execute(&update, [&canonical, &id])
                .map_err(|error| {
                    super::db_error(format!(
                        "update {}.{} during schema v56 inbox migration: {error}",
                        column.table, column.column
                    ))
                })?;
        }
    }
    Ok(())
}

fn load_json_rows(
    transaction: &Transaction<'_>,
    column: &JsonColumn,
) -> Result<Vec<(String, String)>, CliError> {
    let filter = column.filter.map_or_else(
        || format!("json_valid({})", column.column),
        |filter| format!("{filter} AND json_valid({})", column.column),
    );
    let select = format!(
        "SELECT CAST({} AS TEXT), {} FROM {} WHERE {}",
        column.id, column.column, column.table, filter
    );
    let mut statement = transaction.prepare(&select).map_err(|error| {
        super::db_error(format!(
            "prepare {}.{} for schema v56 inbox migration: {error}",
            column.table, column.column
        ))
    })?;
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(|error| {
            super::db_error(format!(
                "read {}.{} for schema v56 inbox migration: {error}",
                column.table, column.column
            ))
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| {
            super::db_error(format!(
                "decode {}.{} for schema v56 inbox migration: {error}",
                column.table, column.column
            ))
        })
}

fn rewrite_status_values(value: &mut Value) -> bool {
    match value {
        Value::Array(values) => values.iter_mut().any(rewrite_status_values),
        Value::Object(fields) => fields.iter_mut().fold(false, |changed, (key, value)| {
            let rewritten =
                if STATUS_KEYS.contains(&key.as_str()) && value.as_str() == Some("backlog") {
                    *value = Value::String("inbox".to_owned());
                    true
                } else {
                    rewrite_status_values(value)
                };
            changed || rewritten
        }),
        _ => false,
    }
}

#[cfg(test)]
#[path = "schema_v56_tests.rs"]
mod tests;
