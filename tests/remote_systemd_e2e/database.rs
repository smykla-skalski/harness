use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const OPERATOR_TABLE: &str = "harness_remote_systemd_e2e_operator_canary";
const CRASH_TABLE: &str = "harness_remote_systemd_e2e_crash_canary";
const OPERATOR_ORIGINAL_VERSION: i64 = 2_000_000_101;
const OPERATOR_MUTATED_VERSION: i64 = 2_000_000_102;
const CRASH_ORIGINAL_VERSION: i64 = 2_000_000_103;
const CRASH_MUTATED_VERSION: i64 = 2_000_000_104;

const ORIGINAL_ROWS: &[(i64, &str)] = &[
    (1, "alpha-before-snapshot"),
    (2, "bravo-before-snapshot"),
    (3, "charlie-before-snapshot"),
];
const MUTATED_ROWS: &[(i64, &str)] = &[
    (1, "alpha-after-snapshot"),
    (3, "charlie-updated-after-snapshot"),
    (4, "delta-added-after-snapshot"),
];

#[derive(Clone, Copy, Debug)]
pub(super) struct DatabaseCanary {
    table: &'static str,
    user_version: i64,
    rows: &'static [(i64, &'static str)],
    migrated_schema: bool,
}

pub(super) const OPERATOR_ORIGINAL: DatabaseCanary = DatabaseCanary {
    table: OPERATOR_TABLE,
    user_version: OPERATOR_ORIGINAL_VERSION,
    rows: ORIGINAL_ROWS,
    migrated_schema: false,
};
pub(super) const OPERATOR_MUTATED: DatabaseCanary = DatabaseCanary {
    table: OPERATOR_TABLE,
    user_version: OPERATOR_MUTATED_VERSION,
    rows: MUTATED_ROWS,
    migrated_schema: true,
};
pub(super) const CRASH_ORIGINAL: DatabaseCanary = DatabaseCanary {
    table: CRASH_TABLE,
    user_version: CRASH_ORIGINAL_VERSION,
    rows: ORIGINAL_ROWS,
    migrated_schema: false,
};
pub(super) const CRASH_MUTATED: DatabaseCanary = DatabaseCanary {
    table: CRASH_TABLE,
    user_version: CRASH_MUTATED_VERSION,
    rows: MUTATED_ROWS,
    migrated_schema: true,
};

pub(super) fn establish_live_canary(
    state_path: &Path,
    canary: DatabaseCanary,
) -> Result<(), String> {
    let database = live_database_path(state_path);
    let inserts = canary
        .rows
        .iter()
        .map(|(id, value)| {
            format!(
                "INSERT INTO {} (id, evidence) VALUES ({id}, '{}');",
                canary.table,
                sql_literal(value)
            )
        })
        .collect::<String>();
    let sql = format!(
        "PRAGMA synchronous=FULL; BEGIN IMMEDIATE; \
         DROP TABLE IF EXISTS {table}; \
         CREATE TABLE {table} (id INTEGER PRIMARY KEY, evidence TEXT NOT NULL); \
         {inserts} PRAGMA user_version={user_version}; COMMIT; \
         PRAGMA wal_checkpoint(FULL);",
        table = canary.table,
        user_version = canary.user_version,
    );
    execute_durable_write(&database, &sql, "establish database generation canary")?;
    assert_database_canary(&database, canary, "established live database canary")
}

pub(super) fn mutate_live_canary(
    state_path: &Path,
    original: DatabaseCanary,
    mutated: DatabaseCanary,
) -> Result<(), String> {
    if original.table != mutated.table {
        return Err("database canary mutation changed tables".to_string());
    }
    assert_live_database(state_path, original, "pre-mutation database canary")?;
    let value = |id| {
        mutated
            .rows
            .iter()
            .find_map(|(row_id, value)| (*row_id == id).then_some(*value))
            .ok_or_else(|| format!("mutated database canary omitted row {id}"))
    };
    let sql = format!(
        "PRAGMA synchronous=FULL; BEGIN IMMEDIATE; \
         ALTER TABLE {table} ADD COLUMN migration_epoch INTEGER NOT NULL DEFAULT {user_version}; \
         CREATE UNIQUE INDEX {table}_evidence_idx ON {table}(evidence); \
         UPDATE {table} SET evidence='{one}' WHERE id=1; \
         DELETE FROM {table} WHERE id=2; \
         UPDATE {table} SET evidence='{three}' WHERE id=3; \
         INSERT INTO {table} (id, evidence) VALUES (4, '{four}'); \
         PRAGMA user_version={user_version}; COMMIT; \
         PRAGMA wal_checkpoint(FULL);",
        table = mutated.table,
        one = sql_literal(value(1)?),
        three = sql_literal(value(3)?),
        four = sql_literal(value(4)?),
        user_version = mutated.user_version,
    );
    let database = live_database_path(state_path);
    execute_durable_write(&database, &sql, "mutate database generation canary")?;
    assert_database_canary(&database, mutated, "mutated live database canary")
}

pub(super) fn assert_live_database(
    state_path: &Path,
    canary: DatabaseCanary,
    label: &str,
) -> Result<(), String> {
    assert_database_canary(&live_database_path(state_path), canary, label)
}

pub(super) fn assert_evidence_database(
    evidence_path: &Path,
    canary: DatabaseCanary,
    label: &str,
) -> Result<(), String> {
    assert_database_canary(&evidence_database_path(evidence_path), canary, label)
}

fn assert_database_canary(
    database: &Path,
    canary: DatabaseCanary,
    label: &str,
) -> Result<(), String> {
    assert_database_integrity(database, label)?;
    let table_count = query(
        database,
        &format!(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='{}';",
            canary.table
        ),
        &format!("inspect {label} table"),
    )?;
    if table_count.trim() != "1" {
        return Err(format!(
            "{label} table count was {table_count:?}, expected 1"
        ));
    }
    assert_schema_generation(database, canary, label)?;
    let user_version = query(database, "PRAGMA user_version;", label)?;
    if user_version.trim() != canary.user_version.to_string() {
        return Err(format!(
            "{label} user_version was {:?}, expected {}",
            user_version.trim(),
            canary.user_version
        ));
    }
    let rows = query(
        database,
        &format!(
            "SELECT id || '|' || evidence FROM {} ORDER BY id;",
            canary.table
        ),
        &format!("inspect {label} rows"),
    )?;
    let observed = rows.lines().collect::<Vec<_>>();
    let expected = canary
        .rows
        .iter()
        .map(|(id, value)| format!("{id}|{value}"))
        .collect::<Vec<_>>();
    if observed
        .iter()
        .copied()
        .eq(expected.iter().map(String::as_str))
    {
        Ok(())
    } else {
        Err(format!(
            "{label} rows were {observed:?}, expected {expected:?}"
        ))
    }
}

fn assert_schema_generation(
    database: &Path,
    canary: DatabaseCanary,
    label: &str,
) -> Result<(), String> {
    let expected = if canary.migrated_schema { "1" } else { "0" };
    let column_count = query(
        database,
        &format!(
            "SELECT COUNT(*) FROM pragma_table_info('{}') WHERE name='migration_epoch';",
            canary.table
        ),
        &format!("inspect {label} migration column"),
    )?;
    let index_count = query(
        database,
        &format!(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type='index' AND name='{}_evidence_idx';",
            canary.table
        ),
        &format!("inspect {label} migration index"),
    )?;
    if column_count.trim() == expected && index_count.trim() == expected {
        Ok(())
    } else {
        Err(format!(
            "{label} migrated schema counts were column={:?}, index={:?}, expected {expected}",
            column_count.trim(),
            index_count.trim()
        ))
    }
}

fn assert_database_integrity(database: &Path, label: &str) -> Result<(), String> {
    let quick_check = query(database, "PRAGMA quick_check;", label)?;
    if quick_check.trim() != "ok" {
        return Err(format!("{label} quick_check failed: {quick_check:?}"));
    }
    let foreign_keys = query(database, "PRAGMA foreign_key_check;", label)?;
    if foreign_keys.trim().is_empty() {
        Ok(())
    } else {
        Err(format!(
            "{label} foreign_key_check failed: {foreign_keys:?}"
        ))
    }
}

fn execute_durable_write(database: &Path, sql: &str, action: &str) -> Result<(), String> {
    let mut command = sqlite_command(database, false);
    command.arg(sql);
    let output = checked(command, action)?;
    let checkpoint = stdout(&output, action)?.trim();
    if !checkpoint.starts_with("0|") {
        return Err(format!(
            "{action} WAL checkpoint did not finish: {checkpoint:?}"
        ));
    }
    for path in [database, database.parent().unwrap_or(database)] {
        let mut sync = sudo(["sync", "-f"]);
        sync.arg(path);
        checked(sync, &format!("sync {action}"))?;
    }
    Ok(())
}

fn query(database: &Path, sql: &str, action: &str) -> Result<String, String> {
    let mut command = sqlite_command(database, true);
    command.arg(sql);
    let output = checked(command, action)?;
    stdout(&output, action).map(str::to_string)
}

fn sql_literal(value: &str) -> String {
    value.replace('\'', "''")
}

fn sqlite_command(database: &Path, read_only: bool) -> Command {
    let mut command = sudo(["sqlite3", "-batch", "-bail"]);
    if read_only {
        command.arg("-readonly");
    }
    command.args(["-cmd", ".timeout 10000"]);
    command.arg(database);
    command
}

fn live_database_path(state_path: &Path) -> PathBuf {
    state_path.join("harness/daemon/external/harness.db")
}

fn evidence_database_path(evidence_path: &Path) -> PathBuf {
    evidence_path.join("daemon/external/harness.db")
}

fn checked(mut command: Command, action: &str) -> Result<Output, String> {
    command.env("LC_ALL", "C");
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "{action} exited with {}; stdout={}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn stdout<'a>(output: &'a Output, action: &str) -> Result<&'a str, String> {
    std::str::from_utf8(&output.stdout).map_err(|error| format!("decode {action} stdout: {error}"))
}

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}
