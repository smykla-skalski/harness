use super::{CliError, Connection, db_error};

const MIGRATION_SQL: &str =
    include_str!("migrations/0032_daemon_v38_task_board_external_create_intents.sql");

#[derive(Debug, Clone, Copy)]
struct ExpectedColumn {
    name: &'static str,
    declared_type: &'static str,
    not_null: bool,
    primary_key: i64,
}

impl ExpectedColumn {
    const fn required(name: &'static str, declared_type: &'static str) -> Self {
        Self {
            name,
            declared_type,
            not_null: true,
            primary_key: 0,
        }
    }

    const fn required_primary(name: &'static str, declared_type: &'static str) -> Self {
        Self {
            name,
            declared_type,
            not_null: true,
            primary_key: 1,
        }
    }

    const fn optional(name: &'static str, declared_type: &'static str) -> Self {
        Self {
            name,
            declared_type,
            not_null: false,
            primary_key: 0,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct StoredColumn {
    name: String,
    declared_type: String,
    not_null: bool,
    default_value: Option<String>,
    primary_key: i64,
    hidden: i64,
}

#[derive(Debug, PartialEq, Eq)]
struct ForeignKeyShape {
    table: String,
    from: String,
    to: String,
    on_update: String,
    on_delete: String,
    match_kind: String,
}

struct IndexShape {
    name: &'static str,
    unique: bool,
    partial: bool,
    columns: &'static [(&'static str, bool)],
    predicate: Option<&'static str>,
}

const EXPECTED_COLUMNS: &[ExpectedColumn] = &[
    ExpectedColumn::required_primary("intent_id", "TEXT"),
    ExpectedColumn::required("item_id", "TEXT"),
    ExpectedColumn::required("item_revision", "INTEGER"),
    ExpectedColumn::required("provider", "TEXT"),
    ExpectedColumn::required("scope_id", "TEXT"),
    ExpectedColumn::required("create_key", "TEXT"),
    ExpectedColumn::required("state", "TEXT"),
    ExpectedColumn::required("create_snapshot_json", "TEXT"),
    ExpectedColumn::required("changed_fields_json", "TEXT"),
    ExpectedColumn::optional("outcome_json", "TEXT"),
    ExpectedColumn::optional("external_ref_json", "TEXT"),
    ExpectedColumn::required("created_at", "TEXT"),
    ExpectedColumn::optional("outcome_recorded_at", "TEXT"),
    ExpectedColumn::optional("attached_at", "TEXT"),
    ExpectedColumn::optional("attached_item_revision", "INTEGER"),
    ExpectedColumn::optional("follow_up_completed_at", "TEXT"),
    ExpectedColumn::optional("follow_up_audit_event_id", "TEXT"),
    ExpectedColumn::required("updated_at", "TEXT"),
];

const INDEX_SHAPES: &[IndexShape] = &[
    IndexShape {
        name: "idx_task_board_external_create_intents_create_key",
        unique: true,
        partial: false,
        columns: &[("provider", false), ("create_key", false)],
        predicate: None,
    },
    IndexShape {
        name: "idx_task_board_external_create_intents_one_active",
        unique: true,
        partial: true,
        columns: &[("item_id", false), ("provider", false)],
        predicate: Some("where state in ('in_flight', 'created')"),
    },
    IndexShape {
        name: "idx_task_board_external_create_intents_active_scope_state",
        unique: false,
        partial: true,
        columns: &[
            ("provider", false),
            ("scope_id", false),
            ("state", false),
            ("updated_at", false),
            ("intent_id", false),
        ],
        predicate: Some("where state in ('in_flight', 'created')"),
    },
    IndexShape {
        name: "idx_task_board_external_create_intents_created_recovery",
        unique: false,
        partial: true,
        columns: &[("outcome_recorded_at", false), ("intent_id", false)],
        predicate: Some("where state = 'created'"),
    },
    IndexShape {
        name: "idx_task_board_external_create_intents_pending_follow_up",
        unique: false,
        partial: true,
        columns: &[
            ("provider", false),
            ("scope_id", false),
            ("attached_at", false),
            ("intent_id", false),
        ],
        predicate: Some(
            "where state = 'attached' and follow_up_completed_at is null and follow_up_audit_event_id is null",
        ),
    },
    IndexShape {
        name: "idx_task_board_external_create_intents_item_history",
        unique: false,
        partial: false,
        columns: &[
            ("item_id", false),
            ("provider", false),
            ("updated_at", true),
            ("intent_id", false),
        ],
        predicate: None,
    },
];

pub(super) fn require_table_shape(conn: &Connection) -> Result<(), CliError> {
    let columns = table_columns(conn)?;
    let foreign_keys = table_foreign_keys(conn)?;
    let definition = normalized_table_sql(conn)?;
    if columns_match(&columns)
        && foreign_keys == [expected_foreign_key()]
        && definition == expected_table_sql()?
    {
        return Ok(());
    }
    Err(db_error(
        "incompatible task_board_external_create_intents schema; refusing destructive repair",
    ))
}

pub(super) fn indexes_need_repair(conn: &Connection) -> Result<bool, CliError> {
    let mut missing = false;
    for shape in INDEX_SHAPES {
        if !index_exists(conn, shape.name)? {
            missing = true;
            continue;
        }
        require_index_shape(conn, shape)?;
    }
    Ok(missing)
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    require_table_shape(conn)?;
    if indexes_need_repair(conn)? {
        return Err(db_error(
            "task-board external create intent repair left required indexes missing",
        ));
    }
    Ok(())
}

fn require_index_shape(conn: &Connection, shape: &IndexShape) -> Result<(), CliError> {
    let (stored_unique, stored_partial) = index_properties(conn, shape.name)?;
    let stored_columns = index_columns(conn, shape.name)?;
    let sql = normalized_index_sql(conn, shape.name)?;
    let columns_match = stored_columns.len() == shape.columns.len()
        && stored_columns.iter().zip(shape.columns).all(
            |((stored_name, stored_desc), (name, desc))| stored_name == name && stored_desc == desc,
        );
    let predicate_matches = shape.predicate.map_or_else(
        || !sql.contains(" where "),
        |expected| sql.ends_with(expected),
    );
    if stored_unique == shape.unique
        && stored_partial == shape.partial
        && columns_match
        && predicate_matches
    {
        return Ok(());
    }
    Err(db_error(format!(
        "incompatible task-board external create intent index '{}'; refusing destructive repair",
        shape.name
    )))
}

fn table_columns(conn: &Connection) -> Result<Vec<StoredColumn>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT name, type, \"notnull\", dflt_value, pk, hidden
             FROM pragma_table_xinfo('task_board_external_create_intents')
             ORDER BY cid",
        )
        .map_err(|error| db_error(format!("prepare external create intent columns: {error}")))?;
    statement
        .query_map([], |row| {
            Ok(StoredColumn {
                name: row.get(0)?,
                declared_type: row.get(1)?,
                not_null: row.get::<_, i64>(2)? != 0,
                default_value: row.get(3)?,
                primary_key: row.get(4)?,
                hidden: row.get(5)?,
            })
        })
        .map_err(|error| db_error(format!("query external create intent columns: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read external create intent columns: {error}")))
}

fn columns_match(stored: &[StoredColumn]) -> bool {
    stored.len() == EXPECTED_COLUMNS.len()
        && stored
            .iter()
            .zip(EXPECTED_COLUMNS)
            .all(|(stored, expected)| {
                stored.name == expected.name
                    && stored.declared_type == expected.declared_type
                    && stored.not_null == expected.not_null
                    && stored.default_value.is_none()
                    && stored.primary_key == expected.primary_key
                    && stored.hidden == 0
            })
}

fn table_foreign_keys(conn: &Connection) -> Result<Vec<ForeignKeyShape>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT \"table\", \"from\", \"to\", on_update, on_delete, match
             FROM pragma_foreign_key_list('task_board_external_create_intents')
             ORDER BY id, seq",
        )
        .map_err(|error| {
            db_error(format!(
                "prepare external create intent foreign keys: {error}"
            ))
        })?;
    statement
        .query_map([], |row| {
            Ok(ForeignKeyShape {
                table: row.get(0)?,
                from: row.get(1)?,
                to: row.get(2)?,
                on_update: row.get(3)?,
                on_delete: row.get(4)?,
                match_kind: row.get(5)?,
            })
        })
        .map_err(|error| {
            db_error(format!(
                "query external create intent foreign keys: {error}"
            ))
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read external create intent foreign keys: {error}")))
}

fn expected_foreign_key() -> ForeignKeyShape {
    ForeignKeyShape {
        table: "task_board_items".into(),
        from: "item_id".into(),
        to: "item_id".into(),
        on_update: "NO ACTION".into(),
        on_delete: "RESTRICT".into(),
        match_kind: "NONE".into(),
    }
}

fn expected_table_sql() -> Result<String, CliError> {
    let table = MIGRATION_SQL
        .split_once("\n\nCREATE UNIQUE INDEX")
        .map(|(table, _)| table)
        .ok_or_else(|| db_error("external create migration has no index boundary"))?;
    let table = table.trim_end_matches(';').replace("IF NOT EXISTS ", "");
    Ok(normalize_sql(&table))
}

fn index_exists(conn: &Connection, index_name: &str) -> Result<bool, CliError> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
        [index_name],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|error| db_error(format!("check {index_name} index existence: {error}")))
}

fn index_properties(conn: &Connection, index_name: &str) -> Result<(bool, bool), CliError> {
    conn.query_row(
        "SELECT \"unique\", partial
         FROM pragma_index_list('task_board_external_create_intents')
         WHERE name = ?1",
        [index_name],
        |row| Ok((row.get::<_, i64>(0)? != 0, row.get::<_, i64>(1)? != 0)),
    )
    .map_err(|error| db_error(format!("read {index_name} index properties: {error}")))
}

fn index_columns(conn: &Connection, index_name: &str) -> Result<Vec<(String, bool)>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT name, \"desc\" FROM pragma_index_xinfo(?1)
             WHERE key = 1 ORDER BY seqno",
        )
        .map_err(|error| db_error(format!("prepare {index_name} index columns: {error}")))?;
    statement
        .query_map([index_name], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? != 0))
        })
        .map_err(|error| db_error(format!("query {index_name} index columns: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read {index_name} index columns: {error}")))
}

fn normalized_index_sql(conn: &Connection, index_name: &str) -> Result<String, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?1",
        [index_name],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| normalize_sql(&sql))
    .map_err(|error| db_error(format!("read {index_name} index definition: {error}")))
}

fn normalized_table_sql(conn: &Connection) -> Result<String, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master
         WHERE type = 'table' AND name = 'task_board_external_create_intents'",
        [],
        |row| row.get::<_, String>(0),
    )
    .map(|sql| normalize_sql(&sql))
    .map_err(|error| {
        db_error(format!(
            "read external create intent table definition: {error}"
        ))
    })
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
