use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error};
use crate::task_board::{
    is_canonical_decided_at, is_canonical_override_actor, is_canonical_override_reason,
};

const VERDICT_DEFINITION: &str = "
triage_override_verdict TEXT
    CONSTRAINT task_board_items_triage_override_verdict_values
    CHECK (triage_override_verdict IS NULL OR triage_override_verdict IN ('todo', 'undecided'))";
const ACTOR_DEFINITION: &str = "
triage_override_actor TEXT
    CONSTRAINT task_board_items_triage_override_actor_coherence
    CHECK (
        (triage_override_verdict IS NULL AND triage_override_actor IS NULL)
        OR (
            triage_override_verdict IS NOT NULL
            AND triage_override_actor IS NOT NULL
            AND length(triage_override_actor) > 0
            AND length(triage_override_actor) <= 256
        )
    )";
const REASON_DEFINITION: &str = "
triage_override_reason TEXT
    CONSTRAINT task_board_items_triage_override_reason_coherence
    CHECK (
        triage_override_reason IS NULL
        OR (triage_override_verdict IS NOT NULL AND length(triage_override_reason) <= 256)
    )";
const SET_AT_DEFINITION: &str = "
triage_override_set_at TEXT
    CONSTRAINT task_board_items_triage_override_set_at_coherence
    CHECK (
        (triage_override_verdict IS NULL AND triage_override_set_at IS NULL)
        OR (
            triage_override_verdict IS NOT NULL
            AND triage_override_set_at IS NOT NULL
            AND triage_override_set_at GLOB '????-??-??T??:??:??Z'
        )
    )";

struct ColumnShape {
    name: &'static str,
    definition: &'static str,
}

/// Additive columns for the durable triage override, added in this order
/// so each later `ALTER TABLE ADD COLUMN` CHECK can reference the
/// already-present `triage_override_verdict` column for all-or-nothing
/// coherence -- `verdict/actor/set_at` are either all present or all absent,
/// and reason is only ever present alongside an active override.
const COLUMNS: &[ColumnShape] = &[
    ColumnShape {
        name: "triage_override_verdict",
        definition: VERDICT_DEFINITION,
    },
    ColumnShape {
        name: "triage_override_actor",
        definition: ACTOR_DEFINITION,
    },
    ColumnShape {
        name: "triage_override_reason",
        definition: REASON_DEFINITION,
    },
    ColumnShape {
        name: "triage_override_set_at",
        definition: SET_AT_DEFINITION,
    },
];

type StoredColumn = (String, bool, Option<String>, i64, i64);

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    for column in COLUMNS {
        if stored_column(conn, column.name)?.is_none() {
            return Ok(true);
        }
        require_column(conn, column)?;
    }
    require_canonical_rows(conn)?;
    Ok(false)
}

pub(super) fn repair_and_stamp(conn: &Connection) -> Result<(), CliError> {
    let transaction =
        Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(|error| {
            db_error(format!(
                "begin task-board triage override schema repair: {error}"
            ))
        })?;
    for column in COLUMNS {
        ensure_column(&transaction, column)?;
    }
    require_complete_shape(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit task-board triage override schema: {error}")))
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    for column in COLUMNS {
        require_column(conn, column)?;
    }
    require_canonical_rows(conn)
}

fn require_canonical_rows(conn: &Connection) -> Result<(), CliError> {
    let mut statement = conn
        .prepare(
            "SELECT triage_override_verdict, triage_override_actor,
                    triage_override_reason, triage_override_set_at
             FROM task_board_items
             WHERE triage_override_verdict IS NOT NULL
                OR triage_override_actor IS NOT NULL
                OR triage_override_reason IS NOT NULL
                OR triage_override_set_at IS NOT NULL",
        )
        .map_err(|error| {
            db_error(format!(
                "prepare task-board triage override validation: {error}"
            ))
        })?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|error| db_error(format!("read task-board triage overrides: {error}")))?;
    for row in rows {
        let (verdict, actor, reason, set_at) =
            row.map_err(|error| db_error(format!("decode task-board triage override: {error}")))?;
        if !override_tuple_is_canonical(
            verdict.as_deref(),
            actor.as_deref(),
            reason.as_deref(),
            set_at.as_deref(),
        ) {
            return Err(db_error(
                "stored task-board triage override is not canonical",
            ));
        }
    }
    Ok(())
}

fn override_tuple_is_canonical(
    verdict: Option<&str>,
    actor: Option<&str>,
    reason: Option<&str>,
    set_at: Option<&str>,
) -> bool {
    match (verdict, actor, set_at) {
        (Some("todo" | "undecided"), Some(actor), Some(set_at)) => {
            is_canonical_override_actor(actor)
                && reason.is_none_or(is_canonical_override_reason)
                && is_canonical_decided_at(set_at)
        }
        (None, None, None) => reason.is_none(),
        _ => false,
    }
}

fn ensure_column(conn: &Connection, column: &ColumnShape) -> Result<(), CliError> {
    if stored_column(conn, column.name)?.is_none() {
        conn.execute_batch(&format!(
            "ALTER TABLE task_board_items ADD COLUMN {};",
            column.definition
        ))
        .map_err(|error| db_error(format!("add task-board {} column: {error}", column.name)))?;
    }
    require_column(conn, column)
}

fn require_column(conn: &Connection, column: &ColumnShape) -> Result<(), CliError> {
    let Some((declared_type, not_null, default_value, primary_key, hidden)) =
        stored_column(conn, column.name)?
    else {
        return Err(db_error(format!(
            "missing task-board {} column",
            column.name
        )));
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
    if metadata_matches && normalize_sql(&table_sql).contains(&normalize_sql(column.definition)) {
        return Ok(());
    }
    Err(db_error(format!(
        "incompatible task-board {} column; refusing destructive repair",
        column.name
    )))
}

fn stored_column(conn: &Connection, name: &str) -> Result<Option<StoredColumn>, CliError> {
    conn.query_row(
        "SELECT type, \"notnull\", dflt_value, pk, hidden
         FROM pragma_table_xinfo('task_board_items') WHERE name = ?1",
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

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
