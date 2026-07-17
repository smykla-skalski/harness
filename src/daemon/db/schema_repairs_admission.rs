use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error};

const MIGRATION_SQL: &str =
    include_str!("migrations/0033_daemon_v39_task_board_policy_admission.sql");
const OBJECTS_MARKER: &str =
    "CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_intents_admission_identity";
const ESTIMATED_TOKENS_DEFINITION: &str = "
estimated_tokens INTEGER
    CHECK (
        estimated_tokens IS NULL
        OR (
            typeof(estimated_tokens) = 'integer'
            AND estimated_tokens BETWEEN 1 AND 9223372036854775807
        )
    )";
const ESTIMATED_COST_DEFINITION: &str = "
estimated_cost_microusd INTEGER
    CHECK (
        estimated_cost_microusd IS NULL
        OR (
            typeof(estimated_cost_microusd) = 'integer'
            AND estimated_cost_microusd BETWEEN 1 AND 9223372036854775807
        )
    )";

struct ObjectShape {
    object_type: &'static str,
    create_kind: &'static str,
    name: &'static str,
}

type StoredColumn = (String, bool, Option<String>, i64, i64);

const OBJECT_SHAPES: &[ObjectShape] = &[
    ObjectShape {
        object_type: "index",
        create_kind: "UNIQUE INDEX",
        name: "task_board_dispatch_intents_admission_identity",
    },
    ObjectShape {
        object_type: "table",
        create_kind: "TABLE",
        name: "task_board_dispatch_admission_decisions",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "UNIQUE INDEX",
        name: "task_board_dispatch_admission_decisions_current_intent",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "UNIQUE INDEX",
        name: "task_board_dispatch_admission_decisions_current_item",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "INDEX",
        name: "task_board_dispatch_admission_decisions_item_history",
    },
    ObjectShape {
        object_type: "table",
        create_kind: "TABLE",
        name: "task_board_dispatch_admission_ledger",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "UNIQUE INDEX",
        name: "task_board_dispatch_admission_ledger_current_requirement",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "INDEX",
        name: "task_board_dispatch_admission_ledger_usage",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "INDEX",
        name: "task_board_dispatch_admission_ledger_intent_generation",
    },
];

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    if item_column_needs_repair(conn, "estimated_tokens", ESTIMATED_TOKENS_DEFINITION)?
        || item_column_needs_repair(conn, "estimated_cost_microusd", ESTIMATED_COST_DEFINITION)?
    {
        return Ok(true);
    }
    for shape in OBJECT_SHAPES {
        let Some(actual) = object_sql(conn, shape)? else {
            return Ok(true);
        };
        let expected = expected_object_sql(shape)?;
        if normalize_sql(&actual) != expected {
            return Err(incompatible_shape(shape.name));
        }
    }
    Ok(false)
}

pub(super) fn repair_and_stamp(conn: &Connection) -> Result<(), CliError> {
    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
        .map_err(|error| db_error(format!("begin task-board admission schema repair: {error}")))?;
    ensure_item_column(
        &transaction,
        "estimated_tokens",
        ESTIMATED_TOKENS_DEFINITION,
    )?;
    ensure_item_column(
        &transaction,
        "estimated_cost_microusd",
        ESTIMATED_COST_DEFINITION,
    )?;
    transaction
        .execute_batch(migration_objects_sql()?)
        .map_err(|error| db_error(format!("create task-board admission schema: {error}")))?;
    require_complete_shape(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit task-board admission schema: {error}")))
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    require_item_column(conn, "estimated_tokens", ESTIMATED_TOKENS_DEFINITION)?;
    require_item_column(conn, "estimated_cost_microusd", ESTIMATED_COST_DEFINITION)?;
    for shape in OBJECT_SHAPES {
        let actual = object_sql(conn, shape)?
            .ok_or_else(|| db_error(format!("missing task-board admission {}", shape.name)))?;
        if normalize_sql(&actual) != expected_object_sql(shape)? {
            return Err(incompatible_shape(shape.name));
        }
    }
    Ok(())
}

fn ensure_item_column(conn: &Connection, name: &str, definition: &str) -> Result<(), CliError> {
    if stored_item_column(conn, name)?.is_none() {
        conn.execute_batch(&format!(
            "ALTER TABLE task_board_items ADD COLUMN {definition};"
        ))
        .map_err(|error| db_error(format!("add task-board {name} column: {error}")))?;
    }
    require_item_column(conn, name, definition)
}

fn item_column_needs_repair(
    conn: &Connection,
    name: &str,
    definition: &str,
) -> Result<bool, CliError> {
    if stored_item_column(conn, name)?.is_none() {
        return Ok(true);
    }
    require_item_column(conn, name, definition)?;
    Ok(false)
}

fn require_item_column(conn: &Connection, name: &str, definition: &str) -> Result<(), CliError> {
    let Some((declared_type, not_null, default_value, primary_key, hidden)) =
        stored_item_column(conn, name)?
    else {
        return Err(db_error(format!("missing task-board {name} column")));
    };
    let table_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'table' AND name = 'task_board_items'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| db_error(format!("read task_board_items definition: {error}")))?;
    let metadata_matches = declared_type == "INTEGER"
        && !not_null
        && default_value.is_none()
        && primary_key == 0
        && hidden == 0;
    if metadata_matches && normalize_sql(&table_sql).contains(&normalize_sql(definition)) {
        return Ok(());
    }
    Err(db_error(format!(
        "incompatible task-board {name} column; refusing destructive repair"
    )))
}

fn stored_item_column(conn: &Connection, name: &str) -> Result<Option<StoredColumn>, CliError> {
    conn.query_row(
        "SELECT type, \"notnull\", dflt_value, pk, hidden
         FROM pragma_table_xinfo('task_board_items')
         WHERE name = ?1",
        [name],
        |row| {
            Ok((
                row.get(0)?,
                row.get::<_, i64>(1)? != 0,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        },
    )
    .optional()
    .map_err(|error| db_error(format!("read task-board {name} column: {error}")))
}

fn object_sql(conn: &Connection, shape: &ObjectShape) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
        [shape.object_type, shape.name],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| db_error(format!("read task-board admission {}: {error}", shape.name)))
}

fn expected_object_sql(shape: &ObjectShape) -> Result<String, CliError> {
    let prefix = format!("CREATE {} IF NOT EXISTS {}", shape.create_kind, shape.name);
    let tail = MIGRATION_SQL
        .split_once(&prefix)
        .map(|(_, tail)| tail)
        .ok_or_else(|| db_error(format!("admission migration is missing {}", shape.name)))?;
    let body = tail
        .split_once(";\n\n")
        .map_or_else(|| tail.trim_end_matches(';'), |(body, _)| body);
    Ok(normalize_sql(&format!(
        "CREATE {} {}{}",
        shape.create_kind, shape.name, body
    )))
}

fn migration_objects_sql() -> Result<&'static str, CliError> {
    MIGRATION_SQL
        .find(OBJECTS_MARKER)
        .map(|offset| &MIGRATION_SQL[offset..])
        .ok_or_else(|| db_error("admission migration has no object boundary"))
}

fn incompatible_shape(name: &str) -> CliError {
    db_error(format!(
        "incompatible task-board admission {name}; refusing destructive repair"
    ))
}

fn normalize_sql(sql: &str) -> String {
    sql.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("IF NOT EXISTS ", "")
        .replace("if not exists ", "")
        .to_ascii_lowercase()
}
