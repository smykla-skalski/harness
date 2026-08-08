use super::{SchemaRepairHooks, query, restore_migration_pragmas};
use crate::AsyncDaemonDb;

/// The hooks are unreachable here: `connect_with_hooks` only threads them
/// through `prepare_legacy_schema`, which is a no-op for a path that does
/// not exist yet (see its own early return), and this test always opens a
/// fresh `tempdir` path.
fn unreachable_repair_hooks() -> SchemaRepairHooks {
    SchemaRepairHooks {
        sync_session: |_, _, _| unreachable!("fresh db never re-runs legacy repairs"),
        backfill_legacy_timelines: |_| unreachable!("fresh db never re-runs legacy repairs"),
    }
}

/// Reading the pragma back through the pool proves nothing: the pool opens
/// connections with `foreign_keys(true)`, so it can answer from a connection
/// that was never suspended. This asserts on the same connection the restore
/// ran against, which is the one handed back to the pool.
#[tokio::test]
async fn restoring_pragmas_applies_every_statement_on_that_connection() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect_with_hooks(
        &dir.path().join("harness.db"),
        &unreachable_repair_hooks(),
    )
    .await
    .expect("open async db");
    let mut conn = db.pool().acquire().await.expect("acquire connection");
    for pragma in [
        "PRAGMA foreign_keys = OFF",
        "PRAGMA legacy_alter_table = ON",
    ] {
        query(pragma)
            .execute(&mut *conn)
            .await
            .expect("suspend pragma");
    }

    restore_migration_pragmas(&mut conn)
        .await
        .expect("restore pragmas");

    let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(&mut *conn)
        .await
        .expect("foreign_keys pragma");
    let legacy_alter_table: i64 = sqlx::query_scalar("PRAGMA legacy_alter_table")
        .fetch_one(&mut *conn)
        .await
        .expect("legacy_alter_table pragma");

    assert_eq!(
        (foreign_keys, legacy_alter_table),
        (1, 0),
        "a statement in the restore never reached the migrator's connection"
    );
}
