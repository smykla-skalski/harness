use sqlx::query_scalar;
use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn partial_signal_wake_claim_migration_still_applies_the_version_stamp() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open current sync daemon db");
    sync_db
        .connection()
        .execute(
            "UPDATE schema_meta SET value = '66' WHERE key = 'version'",
            [],
        )
        .expect("simulate a crash after adding the wake claim column");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("resume partial signal wake claim migration");
    assert_eq!(
        async_db.schema_version().await.expect("schema version"),
        SCHEMA_VERSION
    );
    let recorded = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM _sqlx_migrations WHERE version BETWEEN 72 AND 75",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("load signal wake migration ledger");
    assert_eq!(recorded, 4);
}
