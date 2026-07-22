use rusqlite::Connection;
use std::path::Path;
use tempfile::tempdir;

use super::tests::legacy_v40_fixture_at;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};

const LEGACY_LEAF_SHA256: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const QUARANTINE_TABLE: &str = "task_board_remote_host_quarantines";

#[test]
fn sync_current_v43_restart_refuses_dropped_quarantine_ledger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("sync-drop.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch(&format!("DROP TABLE {QUARANTINE_TABLE};"))
        .expect("drop durable quarantine ledger");
    drop(migrated);

    let error = DaemonDb::open(&path).expect_err("dropped ledger must fail closed");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        !quarantine_ledger_table_exists(&path),
        "a failed restart must never recreate an empty quarantine ledger"
    );
}

#[test]
fn sync_current_v43_restart_refuses_malformed_quarantine_ledger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("sync-malformed.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    malform_quarantine_ledger(migrated.connection());
    drop(migrated);

    let error = DaemonDb::open(&path).expect_err("malformed ledger must fail closed");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    let (sentinel_present, evidence_rows) = malformed_ledger_shape(&path);
    assert!(
        sentinel_present,
        "a failed restart must not replace the malformed ledger with an empty canonical one"
    );
    assert_eq!(
        evidence_rows, 1,
        "the durable operator evidence row must survive the refused repair"
    );
}

#[tokio::test]
async fn async_current_v43_restart_refuses_dropped_quarantine_ledger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("async-drop.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch(&format!("DROP TABLE {QUARANTINE_TABLE};"))
        .expect("drop durable quarantine ledger");
    drop(migrated);

    let error = AsyncDaemonDb::connect(&path)
        .await
        .expect_err("dropped ledger must fail closed on async restart");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        !quarantine_ledger_table_exists(&path),
        "a failed async restart must never recreate an empty quarantine ledger"
    );
}

#[tokio::test]
async fn async_current_v43_restart_refuses_malformed_quarantine_ledger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("async-malformed.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    malform_quarantine_ledger(migrated.connection());
    drop(migrated);

    let error = AsyncDaemonDb::connect(&path)
        .await
        .expect_err("malformed ledger must fail closed on async restart");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    let (sentinel_present, evidence_rows) = malformed_ledger_shape(&path);
    assert!(
        sentinel_present,
        "a failed async restart must not replace the malformed ledger with an empty canonical one"
    );
    assert_eq!(
        evidence_rows, 1,
        "the durable operator evidence row must survive the refused async repair"
    );
}

#[test]
fn sync_current_v43_restart_refuses_dropped_immutability_trigger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("sync-trigger-drop.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch("DROP TRIGGER task_board_remote_host_quarantines_reject_delete;")
        .expect("drop immutability trigger");
    drop(migrated);

    let error = DaemonDb::open(&path).expect_err("dropped trigger must fail closed");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        !trigger_exists(&path, "task_board_remote_host_quarantines_reject_delete"),
        "a refused restart must never recreate a dropped immutability trigger"
    );
    assert_eq!(
        quarantine_evidence_rows(&path),
        1,
        "the evidence row must survive"
    );
}

#[test]
fn sync_current_v43_restart_refuses_noncanonical_immutability_trigger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("sync-trigger-tamper.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch(
            "DROP TRIGGER task_board_remote_host_quarantines_reject_update;
             CREATE TRIGGER task_board_remote_host_quarantines_reject_update
             BEFORE UPDATE ON task_board_remote_host_quarantines
             BEGIN SELECT RAISE(ABORT, 'tampered'); END;",
        )
        .expect("install noncanonical trigger");
    drop(migrated);

    let error = DaemonDb::open(&path).expect_err("noncanonical trigger must fail closed");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        trigger_body(&path, "task_board_remote_host_quarantines_reject_update")
            .contains("tampered"),
        "a refused restart must leave the tampered trigger unrepaired"
    );
}

#[tokio::test]
async fn async_current_v43_restart_refuses_dropped_immutability_trigger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("async-trigger-drop.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch("DROP TRIGGER task_board_remote_host_quarantines_reject_insert;")
        .expect("drop immutability trigger");
    drop(migrated);

    let error = AsyncDaemonDb::connect(&path)
        .await
        .expect_err("dropped trigger must fail closed on async restart");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        !trigger_exists(&path, "task_board_remote_host_quarantines_reject_insert"),
        "a refused async restart must never recreate a dropped immutability trigger"
    );
    assert_eq!(
        quarantine_evidence_rows(&path),
        1,
        "the evidence row must survive"
    );
}

#[tokio::test]
async fn async_current_v43_restart_refuses_noncanonical_immutability_trigger() {
    let temp = tempdir().expect("restart fixture directory");
    let path = temp.path().join("async-trigger-tamper.sqlite3");
    let migrated = migrate_v43_with_quarantine(&path);
    migrated
        .connection()
        .execute_batch(
            "DROP TRIGGER task_board_remote_host_quarantines_reject_delete;
             CREATE TRIGGER task_board_remote_host_quarantines_reject_delete
             BEFORE DELETE ON task_board_remote_host_quarantines
             BEGIN SELECT RAISE(ABORT, 'tampered'); END;",
        )
        .expect("install noncanonical trigger");
    drop(migrated);

    let error = AsyncDaemonDb::connect(&path)
        .await
        .expect_err("noncanonical trigger must fail closed on async restart");
    assert!(
        error.to_string().contains("refusing destructive repair"),
        "unexpected error: {error}"
    );
    assert!(
        trigger_body(&path, "task_board_remote_host_quarantines_reject_delete")
            .contains("tampered"),
        "a refused async restart must leave the tampered trigger unrepaired"
    );
}

/// Build a v43 database whose durable quarantine ledger already holds one row of
/// operator evidence. The transient `_v43_legacy_execution_host_quarantine`
/// settings key is erased by the migration, so the ledger is the only surviving
/// copy - exactly the state where silent empty recreation would lose evidence.
fn migrate_v43_with_quarantine(path: &Path) -> DaemonDb {
    let legacy = legacy_v40_fixture_at(path);
    legacy
        .connection()
        .execute(
            "UPDATE task_board_orchestrator_settings
             SET settings_json = json_set(
                 settings_json, '$.execution_hosts[0].certificate_fingerprint', ?1
             )
             WHERE singleton = 1",
            [LEGACY_LEAF_SHA256],
        )
        .expect("seed legacy leaf pin in settings");
    legacy
        .connection()
        .execute(
            "UPDATE task_board_execution_hosts SET certificate_fingerprint = ?1
             WHERE host_id = 'executor-a'",
            [LEGACY_LEAF_SHA256],
        )
        .expect("seed legacy leaf pin on stored host");
    drop(legacy);

    let migrated = DaemonDb::open(path).expect("migrate v43 with populated quarantine ledger");
    assert_eq!(migrated.schema_version().expect("schema version"), "43");
    assert_eq!(
        quarantine_row_count(migrated.connection()),
        1,
        "fixture must populate the durable quarantine ledger before the damage"
    );
    migrated
}

fn malform_quarantine_ledger(conn: &Connection) {
    conn.execute_batch(&format!(
        "ALTER TABLE {QUARANTINE_TABLE} ADD COLUMN sentinel TEXT NOT NULL DEFAULT 'keep';"
    ))
    .expect("malform durable quarantine ledger");
}

fn quarantine_row_count(conn: &Connection) -> i64 {
    conn.query_row(
        &format!("SELECT COUNT(*) FROM {QUARANTINE_TABLE}"),
        [],
        |row| row.get(0),
    )
    .expect("count quarantine ledger rows")
}

fn quarantine_ledger_table_exists(path: &Path) -> bool {
    let conn = Connection::open(path).expect("reopen database after failed restart");
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [QUARANTINE_TABLE],
            |row| row.get(0),
        )
        .expect("probe quarantine ledger table");
    count > 0
}

/// Returns whether the malformed sentinel column persists and how many evidence
/// rows remain, proving the refused repair left the ledger byte-for-byte intact.
fn malformed_ledger_shape(path: &Path) -> (bool, i64) {
    let conn = Connection::open(path).expect("reopen database after failed restart");
    let sentinel: i64 = conn
        .query_row(
            &format!("SELECT COUNT(*) FROM pragma_table_info('{QUARANTINE_TABLE}') WHERE name = 'sentinel'"),
            [],
            |row| row.get(0),
        )
        .expect("probe malformed sentinel column");
    let rows: i64 = conn
        .query_row(
            &format!("SELECT COUNT(*) FROM {QUARANTINE_TABLE}"),
            [],
            |row| row.get(0),
        )
        .expect("count surviving quarantine evidence rows");
    (sentinel > 0, rows)
}

fn trigger_exists(path: &Path, name: &str) -> bool {
    let conn = Connection::open(path).expect("reopen database after failed restart");
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
            [name],
            |row| row.get(0),
        )
        .expect("probe immutability trigger");
    count > 0
}

fn trigger_body(path: &Path, name: &str) -> String {
    let conn = Connection::open(path).expect("reopen database after failed restart");
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?1",
        [name],
        |row| row.get(0),
    )
    .expect("read immutability trigger body")
}

fn quarantine_evidence_rows(path: &Path) -> i64 {
    let conn = Connection::open(path).expect("reopen database after failed restart");
    conn.query_row(
        &format!("SELECT COUNT(*) FROM {QUARANTINE_TABLE}"),
        [],
        |row| row.get(0),
    )
    .expect("count surviving quarantine evidence rows")
}
