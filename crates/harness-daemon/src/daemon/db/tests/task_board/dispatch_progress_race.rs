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
