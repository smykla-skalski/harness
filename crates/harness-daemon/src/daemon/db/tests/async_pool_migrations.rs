use sha2::{Digest as _, Sha384};
use sqlx::query_scalar;
use tempfile::tempdir;

use super::*;
use super::async_pool_migration_checksums::{
    MODIFIED_V59_CHECKSUM, ORIGINAL_V34_CHECKSUM, ORIGINAL_V59_CHECKSUM,
    SHIPPED_MIGRATION_CHECKSUMS,
};


#[tokio::test]
async fn connect_upgrades_applied_original_v34_migration() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open current sync daemon db");
    restore_original_v34_upgrade_shape(&sync_db);
    drop(sync_db);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute(
        "INSERT INTO policy_workspace (
            singleton, active_canvas_id, workspace_schema_version, updated_at
         ) VALUES (1, 'canvas-1', 1, '2026-07-14T10:00:00Z')",
        [],
    )
    .expect("seed original v34 workspace");
    conn.execute(
        "UPDATE policy_workspace SET spawn_requires_live_policy = 0",
        [],
    )
    .expect("restore original v34 spawn default");
    conn.execute(
        "UPDATE schema_meta SET value = '34' WHERE key = 'version'",
        [],
    )
    .expect("stamp original v34 schema");
    conn.execute_batch(
        "CREATE TABLE _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        );",
    )
    .expect("create migration ledger");
    conn.execute(
        "INSERT INTO _sqlx_migrations (
            version, description, success, checksum, execution_time
         ) VALUES (?1, ?2, 1, ?3, 0)",
        rusqlite::params![
            28_i64,
            "daemon v34 spawn policy",
            hex::decode(ORIGINAL_V34_CHECKSUM).expect("decode v34 checksum")
        ],
    )
    .expect("record original v34 migration");
    drop(conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("upgrade applied original v34 database");

    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        applied_migration_versions(&async_db).await,
        all_migration_versions()
    );
    let requires_live = query_scalar::<_, bool>(
        "SELECT spawn_requires_live_policy FROM policy_workspace WHERE singleton = 1",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("read migrated spawn switch");
    assert!(requires_live, "v35 upgrade must fail closed");
    let has_grant_tracking = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pragma_table_info('task_board_dispatch_intents')
         WHERE name = 'consumed_approval_grant_id'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("inspect migrated dispatch schema");
    assert_eq!(has_grant_tracking, 1);
}

#[tokio::test]
async fn connect_repairs_modified_v59_migration_checksum() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let initial = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open current async daemon db");
    initial.pool().close().await;
    drop(initial);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute(
        "UPDATE _sqlx_migrations SET checksum = ?1 WHERE version = 58",
        [hex::decode(MODIFIED_V59_CHECKSUM).expect("decode modified v59 checksum")],
    )
    .expect("record modified v59 checksum");
    drop(conn);

    let repaired = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("repair modified v59 migration checksum");
    let checksum =
        query_scalar::<_, Vec<u8>>("SELECT checksum FROM _sqlx_migrations WHERE version = 58")
            .fetch_one(repaired.pool())
            .await
            .expect("read repaired v59 checksum");

    assert_eq!(hex::encode_upper(checksum), ORIGINAL_V59_CHECKSUM);
}

#[tokio::test]
async fn connect_repairs_v44_remote_execution_integrity_across_restart() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let initial = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open current async daemon db");
    initial.pool().close().await;
    drop(initial);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute_batch(
        "DROP TRIGGER task_board_remote_assignments_preserve_settlement_receipts;
         DROP INDEX task_board_remote_assignments_controller_scan;
         DELETE FROM _sqlx_migrations WHERE version = 39;
         UPDATE schema_meta SET value = '44' WHERE key = 'version';",
    )
    .expect("restore v44 remote execution shape");
    drop(conn);

    let upgraded = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("upgrade v44 remote execution integrity");
    assert_eq!(
        upgraded.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        applied_migration_versions(&upgraded).await,
        all_migration_versions()
    );
    assert_integrity_objects(&upgraded).await;
    upgraded.pool().close().await;
    drop(upgraded);

    let restarted = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("restart upgraded async daemon db");
    assert_eq!(
        restarted.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
    assert_integrity_objects(&restarted).await;
}

async fn assert_integrity_objects(db: &AsyncDaemonDb) {
    for (object_type, name) in [
        ("index", "task_board_remote_assignments_controller_scan"),
        (
            "trigger",
            "task_board_remote_assignments_preserve_settlement_receipts",
        ),
    ] {
        let count = query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = ?1 AND name = ?2",
        )
        .bind(object_type)
        .bind(name)
        .fetch_one(db.pool())
        .await
        .expect("inspect v45 integrity object");
        assert_eq!(count, 1, "missing {object_type} {name}");
    }
}

fn restore_original_v34_upgrade_shape(db: &DaemonDb) {
    // This compatibility test starts from the current sync snapshot so it can
    // seed one historical SQLx ledger row. A version stamp alone is not a
    // historical schema: strict v43 correctly rejects current remote tables
    // paired with a partially downgraded dispatch table. Restore the remote
    // and dispatch lineage to shapes the v35 -> v43 chain can actually emit,
    // then remove the v35 and v39 effects exercised by that chain.
    harness_db_schema::schema_v43::restore_legacy_v40_for_test(db.connection());
    db.connection()
        .execute_batch(
            "DROP TABLE task_board_dispatch_admission_ledger;
             DROP TABLE task_board_dispatch_admission_decisions;
             DROP INDEX task_board_dispatch_intents_admission_identity;
             ALTER TABLE task_board_dispatch_intents DROP COLUMN compensation_pending;
             ALTER TABLE task_board_items DROP COLUMN estimated_cost_microusd;
             ALTER TABLE task_board_items DROP COLUMN estimated_tokens;
             ALTER TABLE task_board_dispatch_intents DROP COLUMN consumed_approval_grant_id;",
        )
        .expect("restore original v34 admission and dispatch effects");
}

#[test]
fn shipped_daemon_async_migration_checksums_remain_stable() {
    // This test runs in harness-daemon's own `--lib` test target, so
    // `CARGO_MANIFEST_DIR` is this crate's own root (`crates/harness-daemon`).
    // The migrations themselves moved into `harness-daemon-db-core` for #1231.
    let migrations_dir =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../harness-daemon-db-core/src/migrations");
    let mut migration_files = std::fs::read_dir(&migrations_dir)
        .expect("read migrations directory")
        .map(|entry| {
            entry
                .expect("read migration directory entry")
                .file_name()
                .into_string()
                .expect("migration filename is utf-8")
        })
        .filter(|filename| filename.ends_with(".sql"))
        .collect::<Vec<_>>();
    migration_files.sort();
    let expected_files = SHIPPED_MIGRATION_CHECKSUMS
        .iter()
        .map(|(filename, _)| (*filename).to_owned())
        .collect::<Vec<_>>();
    assert_eq!(
        migration_files, expected_files,
        "checksum manifest is incomplete"
    );

    for &(filename, expected_checksum) in SHIPPED_MIGRATION_CHECKSUMS {
        let bytes = std::fs::read(migrations_dir.join(filename)).expect("read migration");
        let actual_checksum = hex::encode_upper(Sha384::digest(bytes));
        assert_eq!(
            actual_checksum, expected_checksum,
            "shipped SQLx migration {filename} changed; add a new migration instead"
        );
    }
}

async fn applied_migration_versions(db: &AsyncDaemonDb) -> Vec<i64> {
    query_scalar::<_, i64>("SELECT version FROM _sqlx_migrations ORDER BY version")
        .fetch_all(db.pool())
        .await
        .expect("query applied migrations")
}
