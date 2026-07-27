use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTriageEscalationConfig};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn enabled_config() -> TaskBoardTriageEscalationConfig {
    TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    }
}

fn inbox_item_no_labels(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Vague title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Inbox;
    item
}

async fn active_escalation_row(db: &AsyncDaemonDb, item_id: &str) -> Option<(String, String, String)> {
    sqlx::query_as::<_, (String, String, String)>(
        "SELECT escalation_id, evidence_fingerprint, status FROM task_board_triage_escalations
         WHERE item_id = ?1 AND status IN ('pending', 'running')",
    )
    .bind(item_id)
    .fetch_optional(db.pool())
    .await
    .expect("query active escalation")
}

async fn escalation_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_triage_escalations")
        .fetch_one(db.pool())
        .await
        .expect("count escalations")
}

#[tokio::test]
async fn an_undecided_item_enqueues_a_pending_escalation_when_enabled() {
    let (_directory, db) = connect().await;
    db.set_triage_escalation_config(enabled_config());

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item");

    let active = active_escalation_row(&db, "item-1")
        .await
        .expect("escalation enqueued");
    assert_eq!(active.2, "pending");
}

#[tokio::test]
async fn escalation_is_never_enqueued_when_the_feature_is_disabled() {
    let (_directory, db) = connect().await;
    // Feature stays off by default -- no set_triage_escalation_config call.

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item");

    assert_eq!(escalation_count(&db).await, 0);
}

#[tokio::test]
async fn a_second_touch_with_unchanged_evidence_does_not_enqueue_a_duplicate() {
    let (_directory, db) = connect().await;
    db.set_triage_escalation_config(enabled_config());

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item");
    let first = active_escalation_row(&db, "item-1")
        .await
        .expect("first escalation");

    // Same fingerprint: an update that changes nothing triage-relevant
    // (only touches a non-fingerprinted field) must not enqueue a second
    // escalation for the item's still-unchanged evidence.
    db.update_task_board_item_with_triage("item-1", |item| {
        item.estimated_tokens = Some(5);
        Ok(true)
    })
    .await
    .expect("update item");

    let after = active_escalation_row(&db, "item-1")
        .await
        .expect("escalation still active");
    assert_eq!(after.0, first.0, "same escalation row, not a fresh one");
    assert_eq!(escalation_count(&db).await, 1);
}

/// C1: proves the migration's lifecycle CHECK accepts superseding a
/// never-started `pending` row (`started_at`/`verdict_token`/`managed_run_id`
/// all stay `NULL`, only `status` and `completed_at` change).
#[tokio::test]
async fn a_fingerprint_change_supersedes_the_still_pending_escalation_and_enqueues_fresh() {
    let (_directory, db) = connect().await;
    db.set_triage_escalation_config(enabled_config());

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item");
    let first = active_escalation_row(&db, "item-1")
        .await
        .expect("first escalation");

    // Change the title: evidence_fingerprint changes, verdict stays
    // Undecided (still no meaningful labels).
    db.update_task_board_item_with_triage("item-1", |item| {
        item.title = "A different vague title".into();
        Ok(true)
    })
    .await
    .expect("update item");

    let second = active_escalation_row(&db, "item-1")
        .await
        .expect("fresh escalation enqueued");
    assert_ne!(second.0, first.0, "a new escalation row, not the stale one");
    assert_ne!(
        second.1, first.1,
        "the fresh row tracks the item's current fingerprint"
    );

    let superseded_status: String = sqlx::query_scalar(
        "SELECT status FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&first.0)
    .fetch_one(db.pool())
    .await
    .expect("load superseded row status");
    assert_eq!(superseded_status, "superseded");

    let shape_ok: (Option<String>, Option<String>, Option<String>, Option<String>) = sqlx::query_as(
        "SELECT started_at, verdict_token, managed_run_id, completed_at
         FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&first.0)
    .fetch_one(db.pool())
    .await
    .expect("load superseded row shape");
    assert_eq!(shape_ok.0, None, "superseded-from-pending keeps started_at NULL");
    assert_eq!(shape_ok.1, None);
    assert_eq!(shape_ok.2, None);
    assert!(shape_ok.3.is_some(), "completed_at is stamped on supersede");
}

#[tokio::test]
async fn an_active_override_suppresses_enqueue() {
    let (_directory, db) = connect().await;
    db.set_triage_escalation_config(enabled_config());

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item");
    // Clear whatever escalation the create produced, then set an override
    // and re-trigger triage via an update -- the override must suppress the
    // enqueue this time.
    sqlx::query("DELETE FROM task_board_triage_escalations")
        .execute(db.pool())
        .await
        .expect("clear escalations");
    db.set_task_board_triage_override(crate::daemon::db::task_board::TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: crate::task_board::TriageVerdict::Undecided,
        actor: "human".into(),
        reason: None,
        expected_item_revision: 1,
        expected_items_change_seq: 1,
    })
    .await
    .expect("set override");

    db.update_task_board_item_with_triage("item-1", |item| {
        item.title = "Yet another vague title".into();
        Ok(true)
    })
    .await
    .expect("update item under override");

    assert_eq!(escalation_count(&db).await, 0);
}

#[tokio::test]
async fn the_queue_depth_bound_suppresses_enqueue_without_erroring_ingress() {
    let (_directory, db) = connect().await;
    let mut config = enabled_config();
    config.max_pending = 1;
    db.set_triage_escalation_config(config);

    db.create_task_board_item_with_triage(inbox_item_no_labels("item-1"))
        .await
        .expect("create item 1");
    let result = db
        .create_task_board_item_with_triage(inbox_item_no_labels("item-2"))
        .await;

    assert!(result.is_ok(), "ingress never errors on a full escalation queue");
    assert_eq!(escalation_count(&db).await, 1);
}
