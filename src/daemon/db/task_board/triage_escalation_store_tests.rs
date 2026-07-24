use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTriageEscalationConfig, TaskBoardTriageEscalationStatus};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    (directory, db)
}

fn backlog_item_no_labels(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Vague title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item
}

#[tokio::test]
async fn claiming_moves_pending_to_running_with_a_token_and_run_id() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item");

    let claimed = db
        .claim_pending_task_board_triage_escalations(2)
        .await
        .expect("claim");

    assert_eq!(claimed.len(), 1);
    assert!(!claimed[0].verdict_token.is_empty());
    assert!(claimed[0].verdict_token.len() >= 16, "token is at least 128 bits");
    assert!(!claimed[0].managed_run_id.is_empty());
    let status: String = sqlx::query_scalar(
        "SELECT status FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .fetch_one(db.pool())
    .await
    .expect("load status");
    assert_eq!(status, "running");
}

#[tokio::test]
async fn claim_respects_the_limit_and_leaves_the_rest_pending() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item 1");
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-2"))
        .await
        .expect("create item 2");

    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim one");

    assert_eq!(claimed.len(), 1);
    let pending_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_triage_escalations WHERE status = 'pending'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count pending");
    assert_eq!(pending_count, 1);
}

#[tokio::test]
async fn sweep_times_out_a_running_row_past_its_deadline() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim");
    // Simulate either an in-process timeout or a daemon restart leaving a
    // running row with no live process: back-date started_at past the
    // deadline directly, since both cases look identical to the sweep.
    sqlx::query(
        "UPDATE task_board_triage_escalations SET started_at = '2020-01-01T00:00:00Z'
         WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .execute(db.pool())
    .await
    .expect("back-date started_at");

    let swept = db
        .sweep_stale_task_board_triage_escalations(180)
        .await
        .expect("sweep");

    assert_eq!(swept, vec![claimed[0].managed_run_id.clone()]);
    let status: String = sqlx::query_scalar(
        "SELECT status FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .fetch_one(db.pool())
    .await
    .expect("load status");
    assert_eq!(status, "timed_out");
}

#[tokio::test]
async fn sweep_leaves_a_freshly_claimed_row_running() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item");
    db.claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim");

    let swept = db
        .sweep_stale_task_board_triage_escalations(180)
        .await
        .expect("sweep");

    assert!(swept.is_empty());
}

/// L2 (spawn failure): failing outright must mark the row `failed`
/// immediately with the real reason, not leave it `running` for the sweep
/// to mislabel `timed_out` a full `timeout_seconds` later.
#[tokio::test]
async fn a_failed_spawn_marks_the_row_failed_with_the_real_reason_not_stuck_running() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim");

    db.fail_running_task_board_triage_escalation(&claimed[0].escalation_id, "codex_server_unavailable")
        .await
        .expect("fail escalation");

    let (status, failure_reason): (String, Option<String>) = sqlx::query_as(
        "SELECT status, failure_reason FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .fetch_one(db.pool())
    .await
    .expect("load escalation");
    assert_eq!(status, "failed");
    assert_eq!(failure_reason.as_deref(), Some("codex_server_unavailable"));

    // A subsequent sweep must not touch an already-terminal row.
    let swept = db
        .sweep_stale_task_board_triage_escalations(0)
        .await
        .expect("sweep");
    assert!(swept.is_empty());
}

#[tokio::test]
async fn status_for_item_reports_pending_then_running_then_nothing() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item_no_labels("item-1"))
        .await
        .expect("create item");

    assert_eq!(
        db.task_board_triage_escalation_status_for_item("item-1")
            .await
            .expect("status"),
        Some(TaskBoardTriageEscalationStatus::Pending)
    );

    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim");
    assert_eq!(
        db.task_board_triage_escalation_status_for_item("item-1")
            .await
            .expect("status"),
        Some(TaskBoardTriageEscalationStatus::Running)
    );

    db.report_task_board_triage_escalation_verdict(
        &claimed[0].escalation_id,
        &claimed[0].verdict_token,
        &claimed[0].evidence_fingerprint,
        crate::task_board::TriageVerdict::Todo,
        "resolved",
    )
    .await
    .expect("report verdict");
    assert_eq!(
        db.task_board_triage_escalation_status_for_item("item-1")
            .await
            .expect("status"),
        None,
        "a terminal escalation is never surfaced as pending/running"
    );
}
