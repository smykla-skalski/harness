use sqlx::{query_as, query_scalar};
use tempfile::tempdir;

use super::tests::{legacy_v40_fixture, legacy_v40_fixture_at};
use super::*;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::{TaskBoardExecutionHostConfig, remote_spki_pin};

const LEGACY_LEAF_SHA256: &str =
    "1111111111111111111111111111111111111111111111111111111111111111";

/// The exact 8-column shape of a durable quarantine ledger row. Comparing the
/// full tuple proves the ledger is byte-for-byte immutable across operations.
type QuarantineRow = (String, String, i64, String, String, String, String, i64);

#[test]
fn migration_pins_tombstone_and_ledger_for_zero_assignment_leaf() {
    let db = legacy_v40_fixture();
    seed_zero_assignment_leaf(&db);

    run(db.connection()).expect("migrate zero-assignment legacy leaf pin");

    // The tombstone parent is created purely from the settings quarantine
    // branch: no assignment references the quarantined host.
    let (role, enabled, leaf): (String, i64, Option<String>) = db
        .connection()
        .query_row(
            "SELECT host_role, enabled, configured_leaf_sha256
             FROM task_board_execution_hosts WHERE host_id = 'executor-a'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("read quarantined host");
    assert_eq!(role, "legacy_tombstone");
    assert_eq!(enabled, 0, "tombstone must stay disabled");
    assert_eq!(leaf, None, "tombstone must carry no trust material");

    let assignment_references: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_remote_assignments WHERE host_id = 'executor-a'",
            [],
            |row| row.get(0),
        )
        .expect("count assignment references");
    assert_eq!(
        assignment_references, 0,
        "the tombstone must exist with zero historical assignment references"
    );

    // The durable ledger still holds the exact operator evidence.
    let ledger: QuarantineRow = db
        .connection()
        .query_row(QUARANTINE_SELECT, [], decode_quarantine_row)
        .expect("read quarantine ledger");
    assert_quarantine_evidence(&ledger);
    let ledger_rows: i64 = db
        .connection()
        .query_row("SELECT COUNT(*) FROM task_board_remote_host_quarantines", [], |row| {
            row.get(0)
        })
        .expect("count ledger rows");
    assert_eq!(ledger_rows, 1);
}

#[tokio::test]
async fn tombstone_repair_disable_remove_readd_keeps_immutable_ledger() {
    let temp = tempdir().expect("tombstone fixture directory");
    let path = temp.path().join("tombstone.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    seed_zero_assignment_leaf(&legacy);
    drop(legacy);

    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("migrate zero-assignment legacy leaf pin");
    assert_eq!(
        host_role_enabled(&db, "executor-a").await,
        ("legacy_tombstone".into(), false)
    );
    let ledger = async_quarantine_row(&db).await;
    assert_quarantine_evidence(&ledger);

    let repaired_pin = remote_spki_pin::encode([0x33; 32]);

    // 1. Exact re-pair: the tombstone flips back to a trusted controller host
    //    whose trust material comes only from the new operator settings.
    replace_hosts(&db, vec![host_config("executor-a", &repaired_pin, true)]).await;
    assert_eq!(
        host_role_enabled(&db, "executor-a").await,
        ("controller_remote".into(), true)
    );
    assert_eq!(configured_leaf(&db, "executor-a").await.as_deref(), Some(repaired_pin.as_str()));
    assert_eq!(async_quarantine_row(&db).await, ledger, "re-pair mutated the immutable ledger");

    // 2. Disable.
    replace_hosts(&db, vec![host_config("executor-a", &repaired_pin, false)]).await;
    assert_eq!(
        host_role_enabled(&db, "executor-a").await,
        ("controller_remote".into(), false)
    );
    assert_eq!(async_quarantine_row(&db).await, ledger, "disable mutated the immutable ledger");

    // 3. Remove.
    replace_hosts(&db, Vec::new()).await;
    assert_eq!(
        host_role_enabled(&db, "executor-a").await,
        ("controller_remote".into(), false)
    );
    assert_eq!(async_quarantine_row(&db).await, ledger, "remove mutated the immutable ledger");

    // 4. Re-add.
    replace_hosts(&db, vec![host_config("executor-a", &repaired_pin, true)]).await;
    assert_eq!(
        host_role_enabled(&db, "executor-a").await,
        ("controller_remote".into(), true)
    );
    assert_eq!(async_quarantine_row(&db).await, ledger, "re-add mutated the immutable ledger");

    // The quarantined leaf never becomes scheduling/trust evidence: the live
    // host's trust is the operator SPKI pin, never the ledger's legacy leaf, and
    // exactly one write-once ledger row persists throughout.
    assert_ne!(
        configured_leaf(&db, "executor-a").await.as_deref(),
        Some(ledger.5.as_str()),
        "the untrusted legacy leaf must never become host trust material"
    );
    assert_eq!(
        query_scalar::<_, i64>("SELECT COUNT(*) FROM task_board_remote_host_quarantines")
            .fetch_one(db.pool())
            .await
            .expect("count ledger rows"),
        1
    );
}

#[test]
fn quarantine_ledger_rejects_every_runtime_write() {
    let db = legacy_v40_fixture();
    seed_zero_assignment_leaf(&db);
    run(db.connection()).expect("migrate zero-assignment legacy leaf pin");
    let before = quarantine_rows(db.connection());
    assert_eq!(before.len(), 1, "fixture must persist exactly one ledger row");

    // INSERT would let a re-paired live host gain fabricated operator evidence.
    let insert = db
        .connection()
        .execute(
            "INSERT INTO task_board_remote_host_quarantines (
                 host_id, reason, source_settings_revision, source_settings_updated_at,
                 legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference,
                 legacy_enabled
             ) VALUES ('executor-a', 'legacy_leaf_certificate_sha256_requires_repair', 7,
                       '2026-07-19T07:59:00Z', 'https://executor.example.test', ?1,
                       'env://HARNESS_REMOTE_TOKEN', 1)",
            [LEGACY_LEAF_SHA256],
        )
        .expect_err("runtime insert must abort");
    assert_immutable(&insert);

    // Even a no-op UPDATE must abort.
    let update = db
        .connection()
        .execute("UPDATE task_board_remote_host_quarantines SET reason = reason", [])
        .expect_err("no-op runtime update must abort");
    assert_immutable(&update);

    // DELETE would silently erase provenance the settings key no longer holds.
    let delete = db
        .connection()
        .execute(
            "DELETE FROM task_board_remote_host_quarantines WHERE host_id = 'executor-a'",
            [],
        )
        .expect_err("runtime delete must abort");
    assert_immutable(&delete);

    assert_eq!(
        quarantine_rows(db.connection()),
        before,
        "the frozen ledger must be byte-identical after every rejected write"
    );
}

#[test]
fn assignment_only_tombstone_without_ledger_row_survives_reopen() {
    let temp = tempdir().expect("assignment-only tombstone fixture directory");
    let path = temp.path().join("assignment-only-tombstone.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    drop(legacy);
    let migrated = DaemonDb::open(&path).expect("migrate legacy remote assignments");
    // A tombstone host that only anchors an archived assignment legitimately has
    // no quarantine ledger row; classification must not impose a pairing
    // invariant. Rebind one already-migrated legacy assignment onto a fresh
    // disabled tombstone rather than fabricate a new assignment.
    migrated
        .connection()
        .execute_batch(
            "INSERT INTO task_board_execution_hosts (
                 host_id, host_role, configuration_revision, enabled, created_at, updated_at
             ) VALUES ('ghost-host', 'legacy_tombstone', 1, 0,
                       '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z');
             UPDATE task_board_remote_assignments SET host_id = 'ghost-host'
             WHERE assignment_id = 'legacy-nullable-assignment';",
        )
        .expect("rebind a migrated legacy assignment onto an assignment-only tombstone");
    drop(migrated);

    // Reopen must accept the assignment-only tombstone as a current schema.
    let reopened = DaemonDb::open(&path)
        .expect("reopen accepts an assignment-only tombstone without a ledger row");
    let tombstone: (String, i64, Option<String>, Option<String>, Option<String>, Option<String>) =
        reopened
            .connection()
            .query_row(
                "SELECT host_role, enabled, configured_endpoint, configured_leaf_sha256,
                        configured_credential_reference, observed_host_instance_id
                 FROM task_board_execution_hosts WHERE host_id = 'ghost-host'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .expect("load tombstone host");
    assert_eq!(
        tombstone,
        ("legacy_tombstone".into(), 0, None, None, None, None),
        "the tombstone stays disabled with no endpoint, pin, credential, or observation"
    );
    let archived: (String, String, i64) = reopened
        .connection()
        .query_row(
            "SELECT host_id, state, legacy_migrated FROM task_board_remote_assignments
             WHERE assignment_id = 'legacy-nullable-assignment'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load rebound archived assignment");
    assert_eq!(
        archived,
        ("ghost-host".into(), "superseded".into(), 1),
        "the archived assignment still anchors the tombstone as superseded legacy evidence"
    );
    let ledger_rows: i64 = reopened
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_remote_host_quarantines WHERE host_id = 'ghost-host'",
            [],
            |row| row.get(0),
        )
        .expect("count ledger rows for the tombstone host");
    assert_eq!(ledger_rows, 0, "an assignment-only tombstone must carry no ledger row");
    let violations: i64 = reopened
        .connection()
        .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| row.get(0))
        .expect("run foreign key check");
    assert_eq!(violations, 0, "the archived assignment foreign key must remain intact");
}

fn assert_immutable(error: &rusqlite::Error) {
    assert!(
        error
            .to_string()
            .contains("task_board_remote_host_quarantines is immutable"),
        "unexpected error: {error}"
    );
}

fn quarantine_rows(conn: &Connection) -> Vec<QuarantineRow> {
    conn.prepare(QUARANTINE_SELECT)
        .expect("prepare quarantine ledger query")
        .query_map([], decode_quarantine_row)
        .expect("query quarantine ledger")
        .collect::<Result<_, _>>()
        .expect("decode quarantine ledger")
}

#[tokio::test]
async fn migrated_planning_and_reviewing_typed_loads_return_none() {
    let temp = tempdir().expect("typed-load fixture directory");
    let path = temp.path().join("typed-load.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    drop(legacy);
    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("migrate legacy remote assignments");

    // The base fixture seeds a planning row and a reviewing row; both migrate to
    // superseded legacy evidence and must be invisible to the typed loader.
    assert!(
        db.task_board_remote_assignment("legacy-assignment")
            .await
            .expect("load migrated planning assignment")
            .is_none(),
        "a migrated planning row must not load through the current typed path"
    );
    assert!(
        db.task_board_remote_assignment("legacy-nullable-assignment")
            .await
            .expect("load migrated reviewing assignment")
            .is_none(),
        "a migrated reviewing row must not load through the current typed path"
    );
}

fn seed_zero_assignment_leaf(db: &DaemonDb) {
    db.connection()
        .execute("DELETE FROM task_board_remote_assignments", [])
        .expect("clear legacy assignments so the quarantined host has zero references");
    db.connection()
        .execute(
            "UPDATE task_board_orchestrator_settings
             SET settings_json = json_set(
                 settings_json, '$.execution_hosts[0].certificate_fingerprint', ?1
             )
             WHERE singleton = 1",
            [LEGACY_LEAF_SHA256],
        )
        .expect("seed legacy leaf pin in settings");
    db.connection()
        .execute(
            "UPDATE task_board_execution_hosts SET certificate_fingerprint = ?1
             WHERE host_id = 'executor-a'",
            [LEGACY_LEAF_SHA256],
        )
        .expect("seed legacy leaf pin on stored host");
}

const QUARANTINE_SELECT: &str =
    "SELECT host_id, reason, source_settings_revision, source_settings_updated_at,
            legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference, legacy_enabled
     FROM task_board_remote_host_quarantines";

fn decode_quarantine_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<QuarantineRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
    ))
}

fn assert_quarantine_evidence(row: &QuarantineRow) {
    assert_eq!(row.0, "executor-a");
    assert_eq!(row.1, "legacy_leaf_certificate_sha256_requires_repair");
    assert_eq!(row.2, 7);
    assert_eq!(row.4, "https://executor.example.test");
    assert_eq!(row.5, LEGACY_LEAF_SHA256);
    assert_eq!(row.6, "env://HARNESS_REMOTE_TOKEN");
    assert_eq!(row.7, 1, "legacy enabled flag is preserved exactly");
}

async fn async_quarantine_row(db: &AsyncDaemonDb) -> QuarantineRow {
    query_as::<_, QuarantineRow>(QUARANTINE_SELECT)
        .fetch_one(db.pool())
        .await
        .expect("read quarantine ledger row")
}

async fn replace_hosts(db: &AsyncDaemonDb, hosts: Vec<TaskBoardExecutionHostConfig>) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load orchestrator settings");
    settings.execution_hosts = hosts;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace orchestrator settings");
}

async fn host_role_enabled(db: &AsyncDaemonDb, host_id: &str) -> (String, bool) {
    query_as("SELECT host_role, enabled FROM task_board_execution_hosts WHERE host_id = ?1")
        .bind(host_id)
        .fetch_one(db.pool())
        .await
        .expect("load execution host row")
}

async fn configured_leaf(db: &AsyncDaemonDb, host_id: &str) -> Option<String> {
    query_scalar("SELECT configured_leaf_sha256 FROM task_board_execution_hosts WHERE host_id = ?1")
        .bind(host_id)
        .fetch_one(db.pool())
        .await
        .expect("load configured leaf pin")
}

fn host_config(host_id: &str, pin: &str, enabled: bool) -> TaskBoardExecutionHostConfig {
    TaskBoardExecutionHostConfig {
        host_id: host_id.into(),
        endpoint: "https://executor.example.test".into(),
        certificate_fingerprint: pin.into(),
        credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
        enabled,
    }
}
