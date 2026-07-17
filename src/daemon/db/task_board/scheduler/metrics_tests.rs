use chrono::Utc;
use sqlx::query;

use super::test_support::{database, instant, seed_run};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::TaskBoardItem;

#[tokio::test]
async fn metrics_count_active_every_terminal_outcome_and_open_conflicts() {
    let db = database().await;
    for (run_id, outcome, completed_at) in [
        ("run-completed", "completed", "2026-07-15T10:00:00Z"),
        ("run-noop", "noop", "2026-07-15T10:01:00Z"),
        ("run-partial", "partial", "2026-07-15T10:02:00Z"),
        ("run-failed", "failed", "2026-07-15T10:03:00Z"),
        ("run-cancelled", "cancelled", "2026-07-15T10:04:00Z"),
    ] {
        seed_run(
            &db,
            run_id,
            "terminal",
            Some(outcome),
            Some(instant(completed_at)),
        )
        .await;
    }
    seed_run(&db, "run-active", "running", None, None).await;
    seed_conflicts(&db).await;

    let before_capture = Utc::now();
    let metrics = load_metrics(&db).await;
    let after_capture = Utc::now();
    assert_eq!(metrics.runs_total, 6);
    assert_eq!(metrics.runs_running, 1);
    assert_eq!(metrics.runs_completed, 1);
    assert_eq!(metrics.runs_noop, 1);
    assert_eq!(metrics.runs_partial, 1);
    assert_eq!(metrics.runs_failed, 1);
    assert_eq!(metrics.runs_cancelled, 1);
    assert_eq!(metrics.open_conflicts, 1);
    let captured_at = instant(&metrics.captured_at);
    assert!(captured_at >= before_capture);
    assert!(captured_at <= after_capture);

    query(
        "UPDATE task_board_orchestrator_runs SET state = 'cancelling' WHERE run_id = 'run-active'",
    )
    .execute(db.pool())
    .await
    .expect("move active run to cancelling");
    assert_eq!(load_metrics(&db).await.runs_running, 1);
}

async fn load_metrics(db: &AsyncDaemonDb) -> crate::task_board::TaskBoardAutomationMetrics {
    db.task_board_automation_metrics()
        .await
        .expect("load automation metrics")
}

async fn seed_conflicts(db: &AsyncDaemonDb) {
    db.create_task_board_item(TaskBoardItem::new(
        "item-metrics".into(),
        "Neutral metrics item".into(),
        String::new(),
        "2026-07-15T09:00:00+00:00".into(),
    ))
    .await
    .expect("create metrics item");
    for (conflict_id, state, resolved_at) in [
        ("conflict-open", "open", None),
        (
            "conflict-resolved",
            "resolved",
            Some("2026-07-15T09:30:00+00:00"),
        ),
    ] {
        query(
            "INSERT INTO task_board_sync_conflicts (
                conflict_id, item_id, provider, external_ref, field, base_value_json,
                local_value_json, remote_value_json, item_revision, state, detected_at,
                resolved_at
             ) VALUES (?1, 'item-metrics', 'github', 'neutral/1', ?1, 'null', 'null',
                       'null', 1, ?2, '2026-07-15T09:15:00+00:00', ?3)",
        )
        .bind(conflict_id)
        .bind(state)
        .bind(resolved_at)
        .execute(db.pool())
        .await
        .expect("seed metric conflict");
    }
}
