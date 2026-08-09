use std::collections::HashMap;

use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    SpawnGateSwitches, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemState,
    build_dispatch_plans_with_policy,
};

#[tokio::test]
async fn review_handoff_during_worker_start_wins_over_dispatch_completion() {
    assert_progress_wins_start_race(
        TaskBoardWorkItemState::AwaitingReview,
        TaskBoardStatus::ToReview,
    )
    .await;
}

#[tokio::test]
async fn terminal_report_during_worker_start_wins_over_dispatch_completion() {
    assert_progress_wins_start_race(TaskBoardWorkItemState::Done, TaskBoardStatus::Done).await;
}

#[tokio::test]
async fn terminal_startup_race_holds_admission_until_worker_settlement() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("open db");
    let item_id = "dispatch-progress-admission-race";
    let work_item_id = "work-progress-admission-race";
    let item = TaskBoardItem::new(
        item_id.into(),
        "Dispatch progress admission race".into(),
        "Body".into(),
        "2026-08-08T00:00:00Z".into(),
    );
    let lifecycle = build_dispatch_plans_with_policy(
        &[item.clone()],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.create_task_board_item(item).await.expect("create item");
    db.link_and_enqueue_task_board_dispatch(
        item_id,
        "session-progress-admission-race",
        work_item_id,
        &lifecycle,
    )
    .await
    .expect("enqueue dispatch");
    let claim = db
        .claim_task_board_dispatch(item_id)
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    db.report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
        board_item_id: item_id.into(),
        work_item_id: work_item_id.into(),
        actor: "worker".into(),
        state: Some(TaskBoardWorkItemState::Done),
        summary: Some("finished during startup".into()),
        progress_percent: None,
        blocked_reason: None,
        sequence: None,
    })
    .await
    .expect("report terminal progress during startup");
    let worker_id = format!("codex-{}", claim.intent_id);
    insert_committed_admission(&db, &claim.intent_id, item_id, &worker_id).await;

    db.complete_task_board_dispatch(&claim.intent_id, &claim.claim_token, &worker_id)
        .await
        .expect("complete dispatch startup");

    assert_eq!(ledger_state(&db, &claim.intent_id).await, "committed");
    db.settle_task_board_work_item_worker(item_id, work_item_id)
        .await
        .expect("record stopped worker");
    assert_eq!(ledger_state(&db, &claim.intent_id).await, "released");
    drop(db);
    let reopened = AsyncDaemonDb::connect(&path).await.expect("reopen db");
    assert_eq!(ledger_state(&reopened, &claim.intent_id).await, "released");
    let worker_settled_at: Option<String> = sqlx::query_scalar(
        "SELECT worker_settled_at FROM task_board_work_item_progress
         WHERE item_id = ?1 AND work_item_id = ?2",
    )
    .bind(item_id)
    .bind(work_item_id)
    .fetch_one(reopened.pool())
    .await
    .expect("read durable worker settlement");
    assert!(worker_settled_at.is_some());
}

async fn insert_committed_admission(
    db: &AsyncDaemonDb,
    intent_id: &str,
    item_id: &str,
    worker_id: &str,
) {
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision, settings_revision,
             decision, policy_json, context_json, requirements_json, blockers_json,
             launch_profile, evaluated_at, next_available_at, is_current, superseded_at, created_at
         ) VALUES ('decision-progress-admission-race', ?1, 99, ?2, 1, 1, 'allowed',
                   '{}', '{}', '[]', '[]', 'workspace_write',
                   '2026-08-08T00:00:00Z', NULL, 0,
                   '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z')",
    )
    .bind(intent_id)
    .bind(item_id)
    .execute(db.pool())
    .await
    .expect("insert admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, window_started_at,
             window_ends_at, state, managed_worker_id, expires_at, reserved_at,
             committed_at, released_at
         ) VALUES ('ledger-progress-admission-race', 'decision-progress-admission-race',
                   'allowed', ?1, 99, ?2, 'concurrency:global', 'concurrency', 'global',
                   1, 1, NULL, NULL, 'committed', ?3, NULL,
                   '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z', NULL)",
    )
    .bind(intent_id)
    .bind(item_id)
    .bind(worker_id)
    .execute(db.pool())
    .await
    .expect("insert committed admission");
}

async fn ledger_state(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("read admission state")
}

async fn assert_progress_wins_start_race(
    progress_state: TaskBoardWorkItemState,
    expected_item_status: TaskBoardStatus,
) {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("open db");
    let item_id = format!("dispatch-progress-{progress_state:?}");
    let work_item_id = format!("work-progress-{progress_state:?}");
    db.create_task_board_item(TaskBoardItem::new(
        item_id.clone(),
        "Dispatch progress race".into(),
        "Body".into(),
        "2026-08-08T00:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let item = db.task_board_item(&item_id).await.expect("load item");
    let lifecycle = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch(
        &item_id,
        "session-progress-race",
        &work_item_id,
        &lifecycle,
    )
    .await
    .expect("enqueue dispatch");
    let claim = db
        .claim_task_board_dispatch(&item_id)
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");

    let report = db
        .report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
            board_item_id: item_id.clone(),
            work_item_id: work_item_id.clone(),
            actor: "worker".into(),
            state: Some(progress_state),
            summary: Some("worker reported before startup committed".into()),
            progress_percent: None,
            blocked_reason: None,
            sequence: None,
        })
        .await
        .expect("report progress during startup");
    assert_eq!(report.item.status, TaskBoardStatus::InProgress);

    let completed = db
        .complete_task_board_dispatch(
            &claim.intent_id,
            &claim.claim_token,
            "codex-dispatch-progress-race",
        )
        .await
        .expect("complete dispatch startup");

    assert_eq!(completed.status, expected_item_status);
    let progress = db
        .task_board_work_item_progress(&item_id)
        .await
        .expect("read progress")
        .expect("progress exists");
    assert_eq!(progress.state, progress_state);
    let intent_status: String =
        sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
            .bind(&claim.intent_id)
            .fetch_one(db.pool())
            .await
            .expect("read dispatch intent");
    assert_eq!(intent_status, "completed");
}
