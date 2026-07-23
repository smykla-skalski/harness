use sqlx::query_scalar;

use super::super::{TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideSetInput};
use super::*;
use crate::task_board::{TaskBoardStatus, TriageVerdict};

#[tokio::test]
async fn clear_audit_identifies_a_fresh_automatic_decision_generation() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: Some("keep ready".into()),
        expected_item_revision: revision(&db, "item-1").await,
        expected_items_change_seq: seq(&db).await,
    })
    .await
    .expect("set override");

    db.update_task_board_item("item-1", |item| {
        item.tags = vec!["needs-info".into()];
        Ok(true)
    })
    .await
    .expect("change evidence without evaluating")
    .expect("item changed");
    assert_eq!(
        db.task_board_triage_history("item-1", None, 10)
            .await
            .expect("history before clear")
            .decisions
            .len(),
        1
    );

    let before_clear_audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.triage_override_cleared' AND subject = ?1",
    )
    .bind("item-1")
    .fetch_one(db.pool())
    .await
    .expect("count clear audits");
    let result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-2".into(),
            expected_item_revision: revision(&db, "item-1").await,
            expected_items_change_seq: seq(&db).await,
        })
        .await
        .expect("clear override");

    assert_eq!(result.item.status, TaskBoardStatus::Backlog);
    assert_eq!(
        db.task_board_triage_history("item-1", None, 10)
            .await
            .expect("history after clear")
            .decisions
            .len(),
        2
    );
    let payload = audit_payload(&db, "task_board.item.triage_override_cleared", "item-1").await;
    assert_eq!(payload["reconciled"], true);
    assert_eq!(payload["automatic_decision"]["outcome_kind"], "decided");
    assert_eq!(
        payload["automatic_decision"]["decision"]["verdict"],
        "undecided"
    );
    assert_eq!(
        payload["automatic_decision"]["decision"]["reason_code"],
        "needs_info_label"
    );
    assert_eq!(
        payload["automatic_decision"]["decision"]["cause"],
        "fingerprint_changed"
    );
    assert_eq!(
        payload["automatic_decision"]["decision"]["evaluator_identity"],
        "task_board.triage.builtin_v1"
    );
    assert_eq!(
        payload["automatic_decision"]["decision"]["evaluator_version"],
        1
    );
    assert!(
        payload["automatic_decision"]["decision"]["decided_at"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
    );
    assert_eq!(
        payload["automatic_decision"]["decision"].get("reason_detail"),
        None,
        "clear audit omits free-form automatic decision detail"
    );
    let after_clear_audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.triage_override_cleared' AND subject = ?1",
    )
    .bind("item-1")
    .fetch_one(db.pool())
    .await
    .expect("count clear audits");
    assert_eq!(after_clear_audits, before_clear_audits + 1);
}
