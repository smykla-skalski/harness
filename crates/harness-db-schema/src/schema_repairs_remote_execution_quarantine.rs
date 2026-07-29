use super::{CliError, Connection, db_error};

const HOST_QUARANTINE_TABLE: &str = "task_board_remote_host_quarantines";

/// The three immutability triggers the v43 migration installs on the quarantine
/// ledger. They are the only structural evidence that a canonically shaped
/// ledger has not had its rows fabricated, mutated, or silently deleted, so
/// classification demands their exact bodies and never recreates them.
const IMMUTABILITY_TRIGGERS: &[&str] = &[
    "task_board_remote_host_quarantines_reject_insert",
    "task_board_remote_host_quarantines_reject_update",
    "task_board_remote_host_quarantines_reject_delete",
];

/// True only when the ledger table is canonical and all three immutability
/// triggers are present with their exact canonical bodies. A canonically shaped
/// table whose triggers are missing or noncanonical returns false so the caller
/// falls through to an incompatible, fail-closed classification.
pub(super) fn current_shape_matches(conn: &Connection) -> Result<bool, CliError> {
    let Some(table_sql) = super::table_sql(conn, HOST_QUARANTINE_TABLE)? else {
        return Ok(false);
    };
    if !super::is_expected_table(&table_sql, HOST_QUARANTINE_TABLE)? {
        return Ok(false);
    }
    for name in IMMUTABILITY_TRIGGERS {
        let Some(actual) = super::object_sql(conn, "trigger", name)? else {
            return Ok(false);
        };
        if super::normalize_sql(&actual) != expected_trigger_sql(name)? {
            return Ok(false);
        }
    }
    Ok(true)
}

/// True only when neither the ledger table nor any immutability trigger exists -
/// the sole shape a pre-v43 legacy database may present.
pub(super) fn legacy_absent(conn: &Connection) -> Result<bool, CliError> {
    if super::table_sql(conn, HOST_QUARANTINE_TABLE)?.is_some() {
        return Ok(false);
    }
    for name in IMMUTABILITY_TRIGGERS {
        if super::object_sql(conn, "trigger", name)?.is_some() {
            return Ok(false);
        }
    }
    Ok(true)
}

fn expected_trigger_sql(name: &str) -> Result<String, CliError> {
    extract_trigger(super::MIGRATION_SQL, name)
}

/// The shared `extract_statement` splits on the first `;`, which lands inside the
/// `SELECT RAISE(ABORT, ...);` body rather than at the trigger's terminating
/// `END;`. Extract from `CREATE TRIGGER <name>` through that closing `END`, then
/// normalize so the comparison ignores incidental whitespace.
fn extract_trigger(sql: &str, name: &str) -> Result<String, CliError> {
    let marker = format!("CREATE TRIGGER {name}");
    let start = sql.find(&marker).ok_or_else(|| {
        db_error(format!(
            "remote execution migration is missing trigger '{name}'"
        ))
    })?;
    let rest = &sql[start..];
    let end = rest.find("END;").ok_or_else(|| {
        db_error(format!(
            "remote execution migration trigger '{name}' is unterminated"
        ))
    })?;
    Ok(super::normalize_sql(&rest[..end + 3]))
}
