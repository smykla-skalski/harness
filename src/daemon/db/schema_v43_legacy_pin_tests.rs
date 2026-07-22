use rusqlite::params;
use sqlx::{Row, query_scalar};
use tempfile::tempdir;

use super::tests::legacy_v40_fixture_at;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::{
    TaskBoardOrchestratorSettings, remote_spki_pin, validate_execution_host_configs,
};

const LEGACY_LEAF_SHA256: &str =
    "1111111111111111111111111111111111111111111111111111111111111111";
const CURRENT_HOST_ID: &str = "executor-b";

#[test]
fn synchronous_upgrade_quarantines_legacy_leaf_pin_and_survives_restart() {
    let temp = tempdir().expect("schema fixture directory");
    let path = temp.path().join("sync.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    seed_mixed_pin_fixture(&legacy);
    drop(legacy);

    let migrated = DaemonDb::open(&path).expect("synchronously migrate legacy leaf pin");
    let settings_json = assert_sync_quarantine(&migrated);
    drop(migrated);

    let reopened = DaemonDb::open(&path).expect("reopen synchronously migrated database");
    assert_eq!(assert_sync_quarantine(&reopened), settings_json);
}

#[tokio::test]
async fn asynchronous_upgrade_quarantines_legacy_leaf_pin_and_survives_restart() {
    let temp = tempdir().expect("schema fixture directory");
    let path = temp.path().join("async.sqlite3");
    let legacy = legacy_v40_fixture_at(&path);
    seed_mixed_pin_fixture(&legacy);
    drop(legacy);

    let migrated = AsyncDaemonDb::connect(&path)
        .await
        .expect("asynchronously migrate legacy leaf pin");
    let settings_json = assert_async_quarantine(&migrated).await;
    migrated.pool().close().await;
    drop(migrated);

    let reopened = AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen asynchronously migrated database");
    assert_eq!(assert_async_quarantine(&reopened).await, settings_json);
}

fn seed_mixed_pin_fixture(db: &DaemonDb) {
    let current_pin = remote_spki_pin::encode([0x22; 32]);
    let settings = serde_json::json!({
        "execution_hosts": [
            {
                "host_id": "executor-a",
                "endpoint": "https://executor.example.test",
                "certificate_fingerprint": LEGACY_LEAF_SHA256,
                "credential_reference": "env://HARNESS_REMOTE_TOKEN",
                "enabled": true
            },
            {
                "host_id": CURRENT_HOST_ID,
                "endpoint": "https://executor-b.example.test",
                "certificate_fingerprint": current_pin.clone(),
                "credential_reference": "env://HARNESS_REMOTE_TOKEN_B",
                "enabled": true
            }
        ]
    })
    .to_string();
    db.connection()
        .execute(
            "UPDATE task_board_orchestrator_settings SET settings_json = ?1
             WHERE singleton = 1",
            [&settings],
        )
        .expect("seed mixed legacy/current host settings");
    db.connection()
        .execute(
            "UPDATE task_board_execution_hosts SET certificate_fingerprint = ?1
             WHERE host_id = 'executor-a'",
            [LEGACY_LEAF_SHA256],
        )
        .expect("seed legacy leaf fingerprint");
    db.connection()
        .execute(
            "INSERT INTO task_board_execution_hosts (
                 host_id, endpoint, certificate_fingerprint, credential_reference,
                 protocol_version, capabilities_json, repositories_json, capacity,
                 active_assignments, state, heartbeat_at, updated_at
             ) VALUES (
                 ?1, 'https://executor-b.example.test', ?2,
                 'env://HARNESS_REMOTE_TOKEN_B', 1, '[\"implementation_write\"]',
                 '[\"acme/widgets\"]', 2, 0, 'healthy',
                 '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z'
             )",
            params![CURRENT_HOST_ID, current_pin],
        )
        .expect("seed current SPKI host alongside legacy leaf host");
}

fn assert_sync_quarantine(db: &DaemonDb) -> String {
    assert_eq!(db.schema_version().expect("schema version"), "43");
    let settings_json: String = db
        .connection()
        .query_row(
            "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .expect("read migrated settings");
    assert_quarantine_json(&settings_json);
    let hosts: Vec<(String, String, i64, String)> = db
        .connection()
        .prepare(
            "SELECT host_id, host_role, enabled, COALESCE(configured_leaf_sha256, '')
             FROM task_board_execution_hosts ORDER BY host_id",
        )
        .expect("prepare migrated host query")
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
        .expect("query migrated hosts")
        .collect::<Result<_, _>>()
        .expect("decode migrated hosts");
    assert_current_hosts(&hosts);
    assert_foreign_keys_clean_sync(db);
    let ledger: Vec<(String, String, i64, String, String, String, String, i64)> = db
        .connection()
        .prepare(
            "SELECT host_id, reason, source_settings_revision, source_settings_updated_at,
                    legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference,
                    legacy_enabled
             FROM task_board_remote_host_quarantines ORDER BY host_id",
        )
        .expect("prepare quarantine ledger query")
        .query_map([], |row| {
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
        })
        .expect("query quarantine ledger")
        .collect::<Result<_, _>>()
        .expect("decode quarantine ledger");
    assert_quarantine_ledger(&ledger);
    settings_json
}

async fn assert_async_quarantine(db: &AsyncDaemonDb) -> String {
    assert_eq!(db.schema_version().await.expect("schema version"), "43");
    let settings_json = query_scalar::<_, String>(
        "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(db.pool())
    .await
    .expect("read asynchronously migrated settings");
    assert_quarantine_json(&settings_json);
    let hosts = sqlx::query(
        "SELECT host_id, host_role, enabled, COALESCE(configured_leaf_sha256, '')
         FROM task_board_execution_hosts ORDER BY host_id",
    )
    .fetch_all(db.pool())
    .await
    .expect("read asynchronously migrated hosts")
    .into_iter()
    .map(|row| (row.get(0), row.get(1), row.get(2), row.get(3)))
    .collect::<Vec<(String, String, i64, String)>>();
    assert_current_hosts(&hosts);
    assert_foreign_keys_clean_async(db).await;
    let ledger = sqlx::query(
        "SELECT host_id, reason, source_settings_revision, source_settings_updated_at,
                legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference,
                legacy_enabled
         FROM task_board_remote_host_quarantines ORDER BY host_id",
    )
    .fetch_all(db.pool())
    .await
    .expect("read quarantine ledger")
    .into_iter()
    .map(|row| {
        (
            row.get(0),
            row.get(1),
            row.get(2),
            row.get(3),
            row.get(4),
            row.get(5),
            row.get(6),
            row.get(7),
        )
    })
    .collect::<Vec<(String, String, i64, String, String, String, String, i64)>>();
    assert_quarantine_ledger(&ledger);
    settings_json
}

fn assert_quarantine_json(settings_json: &str) {
    let raw = serde_json::from_str::<serde_json::Value>(settings_json)
        .expect("decode migrated raw settings");
    let typed = serde_json::from_str::<TaskBoardOrchestratorSettings>(settings_json)
        .expect("decode quarantined typed settings");
    validate_execution_host_configs(&typed.execution_hosts)
        .expect("remaining execution hosts are canonical");
    assert_eq!(typed.execution_hosts.len(), 1);
    assert_eq!(typed.execution_hosts[0].host_id, CURRENT_HOST_ID);

    // The fragile transient settings key must be erased after migration; the
    // exact operator evidence now lives durably in the
    // task_board_remote_host_quarantines ledger, asserted separately.
    assert!(
        raw.get("_v43_legacy_execution_host_quarantine").is_none(),
        "quarantine settings key must be removed after the durable ledger copy"
    );
}

// Rows are (host_id, reason, source_settings_revision, source_settings_updated_at,
// legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference, legacy_enabled).
fn assert_quarantine_ledger(rows: &[(String, String, i64, String, String, String, String, i64)]) {
    assert_eq!(rows.len(), 1, "durable quarantine ledger must retain the exact host");
    assert_eq!(rows[0].0, "executor-a");
    assert_eq!(rows[0].1, "legacy_leaf_certificate_sha256_requires_repair");
    assert_eq!(rows[0].2, 7);
    assert_eq!(rows[0].3, "2026-07-19T07:59:00Z");
    assert_eq!(rows[0].4, "https://executor.example.test");
    assert_eq!(rows[0].5, LEGACY_LEAF_SHA256);
    assert_eq!(rows[0].6, "env://HARNESS_REMOTE_TOKEN");
    assert_eq!(rows[0].7, 1, "legacy enabled flag is preserved exactly");
}

// Rows are (host_id, host_role, enabled, configured_leaf_sha256-or-empty),
// ordered by host_id.
fn assert_current_hosts(hosts: &[(String, String, i64, String)]) {
    assert_eq!(
        hosts.len(),
        2,
        "the quarantined legacy host must survive as an inert tombstone parent \
         alongside the current host"
    );
    // executor-a: inert, trustless, disabled tombstone that only anchors the
    // historical assignment foreign key and can never be selected for admission.
    assert_eq!(hosts[0].0, "executor-a");
    assert_eq!(hosts[0].1, "legacy_tombstone");
    assert_eq!(hosts[0].2, 0, "legacy tombstone must stay disabled");
    assert_eq!(hosts[0].3, "", "legacy tombstone must carry no trust material");
    // executor-b: the current, selectable controller host retains its exact pin.
    assert_eq!(hosts[1].0, CURRENT_HOST_ID);
    assert_eq!(hosts[1].1, "controller_remote");
    assert_eq!(hosts[1].2, 1, "current host stays selectable");
    assert_eq!(hosts[1].3, remote_spki_pin::encode([0x22; 32]));
}

fn assert_foreign_keys_clean_sync(db: &DaemonDb) {
    let violations: i64 = db
        .connection()
        .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })
        .expect("run synchronous foreign key check");
    assert_eq!(
        violations, 0,
        "migrated schema must retain every historical assignment foreign key"
    );
}

async fn assert_foreign_keys_clean_async(db: &AsyncDaemonDb) {
    let violations = query_scalar::<_, i64>("SELECT COUNT(*) FROM pragma_foreign_key_check")
        .fetch_one(db.pool())
        .await
        .expect("run asynchronous foreign key check");
    assert_eq!(
        violations, 0,
        "migrated schema must retain every historical assignment foreign key"
    );
}
