use sqlx::query;

use super::super::{
    TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideSetInput,
    current_triage_override_in_tx,
};
use super::*;
use crate::task_board::{TaskBoardTriageEffectiveSource, TriageVerdict};

#[tokio::test]
async fn clear_without_an_active_override_is_rejected() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let error = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-1".into(),
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect_err("clearing with no active override is rejected");
    assert!(error.to_string().contains("no active triage override"));
}

#[tokio::test]
async fn set_rejects_a_deleted_item_without_partial_writes() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    query("UPDATE task_board_items SET deleted_at = '2026-07-23T00:00:00Z' WHERE item_id = ?1")
        .bind("item-1")
        .execute(db.pool())
        .await
        .expect("mark deleted");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect_err("cannot override a deleted item");
    assert!(error.to_string().contains("deleted"));
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn set_rejects_an_ineligible_item_without_partial_writes() {
    let (_directory, db) = connect().await;
    let mut item = backlog_item("item-1");
    item.work_item_id = Some("dispatch-1".into());
    db.create_task_board_item(item).await.expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect_err("cannot override an already-dispatched item");
    assert!(error.to_string().contains("not eligible"));
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn stale_item_revision_is_rejected_without_partial_writes() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let expected_items_change_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision: 999,
            expected_items_change_seq,
        })
        .await
        .expect_err("stale item revision rejects the set");
    assert!(error.to_string().contains("revision changed"));
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn stale_items_change_seq_is_rejected_without_partial_writes() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq: 999,
        })
        .await
        .expect_err("stale items change sequence rejects the set");
    assert!(error.to_string().contains("sequence changed"));
    assert_eq!(audit_count(&db).await, before_audit_count);
}

#[tokio::test]
async fn set_rejects_item_revision_overflow_without_partial_writes() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    query("UPDATE task_board_items SET revision = ?1 WHERE item_id = ?2")
        .bind(i64::MAX)
        .bind("item-1")
        .execute(db.pool())
        .await
        .expect("set item revision to i64::MAX");
    let expected_items_change_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;

    let error = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision: i64::MAX,
            expected_items_change_seq,
        })
        .await
        .expect_err("item revision overflow rejects the set");
    assert!(error.to_string().contains("out of range"));
    assert_eq!(audit_count(&db).await, before_audit_count);
    assert_eq!(revision(&db, "item-1").await, i64::MAX);
}

#[tokio::test]
async fn each_mutation_bumps_the_items_change_sequence_exactly_once() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let before_seq = seq(&db).await;

    let expected_item_revision = revision(&db, "item-1").await;
    let set_result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq: before_seq,
        })
        .await
        .expect("set override");
    assert_eq!(set_result.items_change_seq, before_seq + 1);
    assert_eq!(seq(&db).await, before_seq + 1);

    let expected_item_revision = revision(&db, "item-1").await;
    let clear_result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-1".into(),
            expected_item_revision,
            expected_items_change_seq: before_seq + 1,
        })
        .await
        .expect("clear override");
    assert_eq!(clear_result.items_change_seq, before_seq + 2);
    assert_eq!(seq(&db).await, before_seq + 2);
}

#[tokio::test]
async fn set_and_clear_each_record_exactly_one_typed_audit_event() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let before_audit_count = audit_count(&db).await;

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: Some("looks ready".into()),
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
    assert_eq!(audit_count(&db).await, before_audit_count + 1);
    let set_payload = audit_payload(&db, "task_board.item.triage_override_set", "item-1").await;
    assert_eq!(set_payload["override"]["actor"], "operator-1");
    assert_eq!(set_payload["override"]["reason"], "looks ready");
    assert_eq!(
        set_payload["cas"]["expected_item_revision"],
        serde_json::json!(expected_item_revision)
    );

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
        item_id: "item-1".into(),
        actor: "operator-2".into(),
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("clear override");
    assert_eq!(audit_count(&db).await, before_audit_count + 2);
    let clear_payload =
        audit_payload(&db, "task_board.item.triage_override_cleared", "item-1").await;
    assert_eq!(clear_payload["cleared_override"]["actor"], "operator-1");
    let clear_actor = audit_actor(&db, "task_board.item.triage_override_cleared", "item-1").await;
    assert_eq!(clear_actor.as_deref(), Some("operator-2"));
}

#[tokio::test]
async fn effective_outcome_falls_back_to_the_automatic_decision_when_no_override_is_active() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;

    let mut transaction = db
        .begin_immediate_transaction("read override")
        .await
        .expect("begin transaction");
    let over = current_triage_override_in_tx(&mut transaction, "item-1")
        .await
        .expect("read override");
    transaction.commit().await.expect("commit");
    assert!(over.is_none());

    let read = db
        .task_board_triage_current("item-1")
        .await
        .expect("read triage current");
    let effective = read.effective.expect("effective outcome");
    assert_eq!(effective.verdict, TriageVerdict::Todo);
    assert_eq!(effective.source, TaskBoardTriageEffectiveSource::Automatic);
    assert!(read.triage_override.is_none());
}
