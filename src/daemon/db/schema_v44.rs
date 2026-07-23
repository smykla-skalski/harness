use rusqlite::Connection;

use super::{CliError, db_error};

const LANES_SQL: &str = include_str!("migrations/0038_daemon_v44_task_board_lane_order.sql");
const LANE_COLUMNS: [(&str, &str); 5] = [
    ("lane_position", "INTEGER"),
    ("lane_origin", "TEXT"),
    ("lane_actor", "TEXT"),
    ("lane_producer", "TEXT"),
    ("lane_set_at", "TEXT"),
];
const LANE_TRIGGERS: [&str; 2] = [
    "task_board_items_lane_coherence_insert",
    "task_board_items_lane_coherence_update",
];
const ADD_LANE_POSITION_SQL: &str = "ALTER TABLE task_board_items ADD COLUMN lane_position INTEGER CONSTRAINT task_board_items_lane_position_range CHECK (lane_position BETWEEN 0 AND 4294967295)";
const ADD_LANE_ORIGIN_SQL: &str = "ALTER TABLE task_board_items ADD COLUMN lane_origin TEXT CONSTRAINT task_board_items_lane_origin_values CHECK (lane_origin IN ('manual', 'automatic') OR lane_origin IS NULL)";
const ADD_LANE_ACTOR_SQL: &str = "ALTER TABLE task_board_items ADD COLUMN lane_actor TEXT";
const ADD_LANE_PRODUCER_SQL: &str = "ALTER TABLE task_board_items ADD COLUMN lane_producer TEXT";
const ADD_LANE_SET_AT_SQL: &str = "ALTER TABLE task_board_items ADD COLUMN lane_set_at TEXT";
const POSITION_INDEX_SQL: &str = "CREATE UNIQUE INDEX task_board_items_live_lane_position
    ON task_board_items(status, lane_position)
    WHERE deleted_at IS NULL AND lane_position IS NOT NULL";
const ORDER_INDEX_SQL: &str = "CREATE INDEX task_board_items_live_lane_order
    ON task_board_items(status, lane_position, priority DESC, created_at, item_id)
    WHERE deleted_at IS NULL";

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    for (column, _) in LANE_COLUMNS {
        add_column_if_missing(conn, column)?;
    }
    require_lane_column_shape(conn)?;
    require_lane_data_coherence(conn)?;
    rebuild_indexes(conn)?;
    rebuild_coherence_triggers(conn)?;
    conn.execute(
        "UPDATE schema_meta SET value = '44' WHERE key = 'version'",
        [],
    )
    .map(|_| ())
    .map_err(|error| db_error(format!("stamp schema v44: {error}")))
}

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    if LANE_COLUMNS
        .iter()
        .any(|(column, _)| !column_exists(conn, column).unwrap_or(false))
    {
        return Ok(true);
    }
    require_lane_column_shape(conn)?;
    require_lane_data_coherence(conn)?;
    if !index_matches(
        conn,
        "task_board_items_live_lane_position",
        POSITION_INDEX_SQL,
    )? || !index_matches(conn, "task_board_items_live_lane_order", ORDER_INDEX_SQL)?
    {
        return Ok(true);
    }
    for trigger in LANE_TRIGGERS {
        if !trigger_matches(conn, trigger)? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn add_column_if_missing(conn: &Connection, column: &str) -> Result<(), CliError> {
    if column_exists(conn, column)? {
        return Ok(());
    }
    let sql = match column {
        "lane_position" => ADD_LANE_POSITION_SQL,
        "lane_origin" => ADD_LANE_ORIGIN_SQL,
        "lane_actor" => ADD_LANE_ACTOR_SQL,
        "lane_producer" => ADD_LANE_PRODUCER_SQL,
        "lane_set_at" => ADD_LANE_SET_AT_SQL,
        _ => {
            return Err(db_error(format!(
                "unknown task-board lane column: {column}"
            )));
        }
    };
    conn.execute(sql, [])
        .map(|_| ())
        .map_err(|error| db_error(format!("add task_board_items.{column}: {error}")))
}

fn require_lane_column_shape(conn: &Connection) -> Result<(), CliError> {
    for (column, expected_type) in LANE_COLUMNS {
        let (actual, not_null, default_value, primary_key, hidden) = conn
            .query_row(
                "SELECT type, \"notnull\", dflt_value, pk, hidden
                 FROM pragma_table_xinfo('task_board_items') WHERE name = ?1",
                [column],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .map_err(|error| db_error(format!("read task_board_items.{column}: {error}")))?;
        if !actual.eq_ignore_ascii_case(expected_type)
            || not_null != 0
            || default_value.is_some()
            || primary_key != 0
            || hidden != 0
        {
            return Err(db_error(format!(
                "refusing destructive repair for task_board_items.{column}: expected nullable {expected_type} without a default"
            )));
        }
    }
    let table_sql = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'task_board_items'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map_err(|error| db_error(format!("read task_board_items schema SQL: {error}")))?;
    for fragment in [
        "constraint task_board_items_lane_position_range check (lane_position between 0 and 4294967295)",
        "constraint task_board_items_lane_origin_values check (lane_origin in ('manual', 'automatic') or lane_origin is null)",
    ] {
        if !normalize_sql(&table_sql).contains(fragment) {
            return Err(db_error(format!(
                "refusing incomplete task-board lane schema: missing {fragment}"
            )));
        }
    }
    Ok(())
}

fn require_lane_data_coherence(conn: &Connection) -> Result<(), CliError> {
    let incoherent: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM task_board_items WHERE (
                (lane_position IS NULL AND lane_origin IS NULL AND lane_actor IS NULL
                    AND lane_producer IS NULL AND lane_set_at IS NULL)
                OR (lane_position IS NOT NULL AND lane_origin = 'manual'
                    AND COALESCE(trim(lane_actor), '') <> '' AND lane_producer IS NULL
                    AND length(lane_actor) <= 256 AND COALESCE(trim(lane_set_at), '') <> ''
                    AND length(lane_set_at) <= 128)
                OR (lane_position IS NOT NULL AND lane_origin = 'automatic'
                    AND lane_actor IS NULL AND COALESCE(trim(lane_producer), '') <> ''
                    AND length(lane_producer) <= 256 AND COALESCE(trim(lane_set_at), '') <> ''
                    AND length(lane_set_at) <= 128)
            ) IS NOT TRUE",
            [],
            |row| row.get(0),
        )
        .map_err(|error| db_error(format!("validate task-board lane rows: {error}")))?;
    if incoherent == 0 {
        return Ok(());
    }
    Err(db_error(format!(
        "refusing incomplete task-board lane schema with {incoherent} incoherent rows"
    )))
}

fn rebuild_indexes(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(
        "DROP INDEX IF EXISTS task_board_items_live_lane_position;
         DROP INDEX IF EXISTS task_board_items_live_lane_order;
         CREATE UNIQUE INDEX task_board_items_live_lane_position
             ON task_board_items(status, lane_position)
             WHERE deleted_at IS NULL AND lane_position IS NOT NULL;
         CREATE INDEX task_board_items_live_lane_order
             ON task_board_items(status, lane_position, priority DESC, created_at, item_id)
             WHERE deleted_at IS NULL;",
    )
    .map_err(|error| db_error(format!("rebuild task-board lane indexes: {error}")))
}

fn rebuild_coherence_triggers(conn: &Connection) -> Result<(), CliError> {
    conn.execute_batch(
        "DROP TRIGGER IF EXISTS task_board_items_lane_coherence_insert;
         DROP TRIGGER IF EXISTS task_board_items_lane_coherence_update;",
    )
    .map_err(|error| db_error(format!("drop task-board lane coherence triggers: {error}")))?;
    let trigger_sql = LANES_SQL
        .split("UPDATE schema_meta")
        .next()
        .ok_or_else(|| db_error("parse task-board lane migration SQL"))?
        .split("CREATE TRIGGER")
        .skip(1)
        .fold(String::new(), |mut sql, trigger| {
            sql.push_str("CREATE TRIGGER");
            sql.push_str(trigger);
            sql
        });
    conn.execute_batch(&trigger_sql).map_err(|error| {
        db_error(format!(
            "create task-board lane coherence triggers: {error}"
        ))
    })
}

fn column_exists(conn: &Connection, column: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('task_board_items') WHERE name = ?1",
        [column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count == 1)
    .map_err(|error| db_error(format!("check task_board_items.{column}: {error}")))
}

fn index_matches(conn: &Connection, index: &str, expected: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?1",
        [index],
        |row| row.get::<_, String>(0),
    )
    .map(|actual| normalize_sql(&actual) == normalize_sql(expected))
    .or_else(|error| match error {
        rusqlite::Error::QueryReturnedNoRows => Ok(false),
        error => Err(error),
    })
    .map_err(|error| db_error(format!("check task-board lane index {index}: {error}")))
}

fn trigger_matches(conn: &Connection, trigger: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
        [trigger],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| {
        migration_trigger_sql(trigger)
            .is_some_and(|expected| normalize_sql(&sql) == normalize_sql(&expected))
    })
    .or_else(|error| match error {
        rusqlite::Error::QueryReturnedNoRows => Ok(false),
        error => Err(error),
    })
    .map_err(|error| db_error(format!("check task-board lane trigger {trigger}: {error}")))
}

fn normalize_sql(sql: &str) -> String {
    let mut normalized = String::new();
    let mut quoted = None;
    let mut whitespace = false;
    let mut characters = sql.trim().trim_end_matches(';').trim().chars().peekable();
    while characters.peek().is_some() {
        let character = characters.next().expect("peeked SQL character");
        if let Some(quote) = quoted {
            normalized.push(character);
            if character == quote {
                if characters.peek() == Some(&quote) {
                    normalized.push(characters.next().expect("quoted SQL escape"));
                } else {
                    quoted = None;
                }
            }
            continue;
        }
        if character == '-' && characters.peek() == Some(&'-') {
            characters.next();
            while characters.next().is_some_and(|character| character != '\n') {}
            whitespace = !normalized.is_empty();
            continue;
        }
        if character == '/' && characters.peek() == Some(&'*') {
            characters.next();
            let mut previous = None;
            while characters.peek().is_some() {
                let comment_character = characters.next().expect("peeked SQL comment character");
                if previous == Some('*') && comment_character == '/' {
                    break;
                }
                previous = Some(comment_character);
            }
            whitespace = !normalized.is_empty();
            continue;
        }
        if character == '\'' || character == '"' {
            if whitespace && !normalized.is_empty() {
                normalized.push(' ');
            }
            whitespace = false;
            normalized.push(character);
            quoted = Some(character);
        } else if character.is_whitespace() {
            whitespace = !normalized.is_empty();
        } else {
            if whitespace {
                normalized.push(' ');
                whitespace = false;
            }
            normalized.extend(character.to_lowercase());
        }
    }
    normalized
}

fn migration_trigger_sql(trigger: &str) -> Option<String> {
    LANES_SQL
        .split("CREATE TRIGGER ")
        .skip(1)
        .map(|sql| format!("CREATE TRIGGER {sql}"))
        .find(|sql| sql.starts_with(&format!("CREATE TRIGGER {trigger}")))
        .map(|sql| {
            sql.split("UPDATE schema_meta")
                .next()
                .expect("trigger SQL prefix exists")
                .trim()
                .to_owned()
        })
}

#[cfg(test)]
#[path = "schema_v44_tests.rs"]
mod tests;
