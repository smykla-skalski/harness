use sqlx::Row;

use crate::daemon::db::{AsyncDaemonDb, AsyncDaemonDbConnect};

use super::sql::{ADMISSION_RECOVERY_FOR_WORKER_SQL, ADMISSION_RECOVERY_SQL};

#[tokio::test]
async fn startup_recovery_avoids_lifetime_ledger_scans() {
    let directory = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("open database");

    let startup = query_plan(&db, ADMISSION_RECOVERY_SQL).await;
    let exact = query_plan(&db, ADMISSION_RECOVERY_FOR_WORKER_SQL).await;

    assert!(
        startup
            .iter()
            .any(|detail| detail
                .contains("task_board_dispatch_admission_ledger_current_requirement")),
        "startup plan did not use the active-admission index: {startup:#?}"
    );
    assert!(
        startup.iter().any(|detail| detail
            .contains("task_board_dispatch_admission_ledger_intent_generation")),
        "startup plan did not probe released debt by exact intent: {startup:#?}"
    );
    assert!(
        startup
            .iter()
            .any(|detail| detail.contains("idx_task_board_work_item_progress_recovery")),
        "startup plan did not use the active-progress index: {startup:#?}"
    );
    assert!(
        exact.iter().any(|detail| detail
            .contains("task_board_dispatch_admission_ledger_intent_generation")),
        "exact recovery plan did not use its intent index: {exact:#?}"
    );
    assert!(
        startup
            .iter()
            .filter(|detail| detail.contains("SCAN ledger"))
            .all(|detail| detail.contains("current_requirement")),
        "startup plan contains a lifetime ledger scan: {startup:#?}"
    );
    assert!(
        startup
            .iter()
            .filter(|detail| detail.contains("SCAN progress"))
            .all(|detail| detail.contains("idx_task_board_work_item_progress_recovery")),
        "startup plan contains a lifetime progress scan: {startup:#?}"
    );
}

async fn query_plan(db: &AsyncDaemonDb, sql: &str) -> Vec<String> {
    sqlx::query(sqlx::AssertSqlSafe(format!("EXPLAIN QUERY PLAN {sql}")))
        .fetch_all(db.pool())
        .await
        .expect("explain recovery query")
        .into_iter()
        .map(|row| row.get(3))
        .collect()
}
