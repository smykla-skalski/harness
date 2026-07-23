use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error};

const MIGRATION_SQL: &str = include_str!("migrations/0040_daemon_v46_task_board_triage.sql");
const OBJECTS_MARKER: &str = "CREATE TABLE IF NOT EXISTS task_board_triage_decisions";
const TOMBSTONE_CAUSE_DEFINITION: &str = "
tombstone_cause TEXT
    CONSTRAINT task_board_items_tombstone_cause_values
    CHECK (
        tombstone_cause IS NULL
        OR (deleted_at IS NOT NULL AND tombstone_cause IN ('manual', 'provider_exclusion'))
    )";

type StoredColumn = (String, bool, Option<String>, i64, i64);

struct ObjectShape {
    object_type: &'static str,
    create_kind: &'static str,
    name: &'static str,
}

const OBJECT_SHAPES: &[ObjectShape] = &[
    ObjectShape {
        object_type: "table",
        create_kind: "TABLE",
        name: "task_board_triage_decisions",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "UNIQUE INDEX",
        name: "task_board_triage_decisions_current",
    },
    ObjectShape {
        object_type: "index",
        create_kind: "INDEX",
        name: "task_board_triage_decisions_item_history",
    },
];

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    if tombstone_cause_needs_repair(conn)? {
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
        .map_err(|error| db_error(format!("begin task-board triage schema repair: {error}")))?;
    ensure_tombstone_cause_column(&transaction)?;
    transaction
        .execute_batch(migration_objects_sql()?)
        .map_err(|error| db_error(format!("create task-board triage schema: {error}")))?;
    require_complete_shape(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit task-board triage schema: {error}")))
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    require_tombstone_cause_column(conn)?;
    for shape in OBJECT_SHAPES {
        let actual = object_sql(conn, shape)?
            .ok_or_else(|| db_error(format!("missing task-board triage {}", shape.name)))?;
        if normalize_sql(&actual) != expected_object_sql(shape)? {
            return Err(incompatible_shape(shape.name));
        }
    }
    Ok(())
}

fn ensure_tombstone_cause_column(conn: &Connection) -> Result<(), CliError> {
    if stored_tombstone_cause_column(conn)?.is_none() {
        conn.execute_batch(&format!(
            "ALTER TABLE task_board_items ADD COLUMN {TOMBSTONE_CAUSE_DEFINITION};"
        ))
        .map_err(|error| db_error(format!("add task-board tombstone_cause column: {error}")))?;
    }
    require_tombstone_cause_column(conn)
}

fn tombstone_cause_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    if stored_tombstone_cause_column(conn)?.is_none() {
        return Ok(true);
    }
    require_tombstone_cause_column(conn)?;
    Ok(false)
}

fn require_tombstone_cause_column(conn: &Connection) -> Result<(), CliError> {
    let Some((declared_type, not_null, default_value, primary_key, hidden)) =
        stored_tombstone_cause_column(conn)?
    else {
        return Err(db_error("missing task-board tombstone_cause column"));
    };
    let table_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'task_board_items'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| db_error(format!("read task_board_items definition: {error}")))?;
    let metadata_matches = declared_type == "TEXT"
        && !not_null
        && default_value.is_none()
        && primary_key == 0
        && hidden == 0;
    if metadata_matches
        && normalize_sql(&table_sql).contains(&normalize_sql(TOMBSTONE_CAUSE_DEFINITION))
    {
        return Ok(());
    }
    Err(db_error(
        "incompatible task-board tombstone_cause column; refusing destructive repair",
    ))
}

fn stored_tombstone_cause_column(conn: &Connection) -> Result<Option<StoredColumn>, CliError> {
    conn.query_row(
        "SELECT type, \"notnull\", dflt_value, pk, hidden
         FROM pragma_table_xinfo('task_board_items') WHERE name = 'tombstone_cause'",
        [],
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
    .map_err(|error| db_error(format!("read task-board tombstone_cause column: {error}")))
}

fn object_sql(conn: &Connection, shape: &ObjectShape) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
        [shape.object_type, shape.name],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| db_error(format!("read task-board triage {}: {error}", shape.name)))
}

fn expected_object_sql(shape: &ObjectShape) -> Result<String, CliError> {
    let prefix = format!("CREATE {} IF NOT EXISTS {}", shape.create_kind, shape.name);
    let tail = MIGRATION_SQL
        .split_once(&prefix)
        .map(|(_, tail)| tail)
        .ok_or_else(|| db_error(format!("triage migration is missing {}", shape.name)))?;
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
        .ok_or_else(|| db_error("triage migration has no object boundary"))
}

fn incompatible_shape(name: &str) -> CliError {
    db_error(format!(
        "incompatible task-board triage {name}; refusing destructive repair"
    ))
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
