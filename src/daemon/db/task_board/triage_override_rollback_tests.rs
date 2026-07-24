use sqlx::query;
use sqlx::query_scalar;

use super::super::{TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideSetInput};
use super::*;
use crate::task_board::TriageVerdict;

struct ItemSnapshot {
    revision: i64,
    status: String,
    lane_position: Option<i64>,
    lane_origin: Option<String>,
    lane_actor: Option<String>,
    lane_set_at: Option<String>,
    triage_override_verdict: Option<String>,
    triage_override_actor: Option<String>,
    triage_override_reason: Option<String>,
    triage_override_set_at: Option<String>,
}

async fn item_snapshot(db: &AsyncDaemonDb, item_id: &str) -> ItemSnapshot {
    let row = sqlx::query(
        "SELECT revision, status, lane_position, lane_origin, lane_actor, lane_set_at,
                triage_override_verdict, triage_override_actor, triage_override_reason,
                triage_override_set_at
         FROM task_board_items WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read item row");
    use sqlx::Row;
    ItemSnapshot {
        revision: row.get("revision"),
        status: row.get("status"),
        lane_position: row.get("lane_position"),
        lane_origin: row.get("lane_origin"),
        lane_actor: row.get("lane_actor"),
        lane_set_at: row.get("lane_set_at"),
        triage_override_verdict: row.get("triage_override_verdict"),
        triage_override_actor: row.get("triage_override_actor"),
        triage_override_reason: row.get("triage_override_reason"),
        triage_override_set_at: row.get("triage_override_set_at"),
    }
}

impl PartialEq for ItemSnapshot {
    fn eq(&self, other: &Self) -> bool {
        self.revision == other.revision
            && self.status == other.status
            && self.lane_position == other.lane_position
            && self.lane_origin == other.lane_origin
            && self.lane_actor == other.lane_actor
            && self.lane_set_at == other.lane_set_at
            && self.triage_override_verdict == other.triage_override_verdict
            && self.triage_override_actor == other.triage_override_actor
            && self.triage_override_reason == other.triage_override_reason
            && self.triage_override_set_at == other.triage_override_set_at
    }
}

async fn decision_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("count decisions")
}

/// Seeds a manually anchored Todo sibling at slot 0, so a later override set
/// promoting `item_id` to Todo must shift it -- proving a failed final audit
/// write rolls back that shifted row too, not just the candidate.
async fn anchor_sibling_at_todo_slot_zero(db: &AsyncDaemonDb, item_id: &str) {
    db.create_task_board_item(backlog_item(item_id))
        .await
        .expect("seed sibling");
    query(
        "UPDATE task_board_items SET
             status = 'todo', lane_position = 0, lane_origin = 'manual',
             lane_actor = 'human-1', lane_set_at = '2026-07-23T00:00:00Z'
         WHERE item_id = ?1",
    )
    .bind(item_id)
    .execute(db.pool())
    .await
    .expect("anchor sibling manually");
}

#[tokio::test]
async fn set_rolls_back_every_write_when_the_final_audit_insert_fails() {
    let (_directory, db) = connect().await;
    anchor_sibling_at_todo_slot_zero(&db, "sibling-0").await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let before_item = item_snapshot(&db, "item-1").await;
    let before_sibling = item_snapshot(&db, "sibling-0").await;
    let before_seq = seq(&db).await;
    let before_decisions = decision_count(&db, "item-1").await;
    let before_audit_count = audit_count(&db).await;

    query(
        "CREATE TRIGGER fail_triage_override_set_audit
         BEFORE INSERT ON audit_events
         WHEN NEW.kind = 'task_board.item.triage_override_set'
         BEGIN SELECT RAISE(ABORT, 'simulated triage override set audit failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install audit failure trigger");

    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect_err("a failed audit write must fail the whole set");

    query("DROP TRIGGER fail_triage_override_set_audit")
        .execute(db.pool())
        .await
        .expect("remove audit failure trigger");

    assert!(
        item_snapshot(&db, "item-1").await == before_item,
        "the candidate item's status/placement/override tuple must roll back byte-for-byte"
    );
    assert!(
        item_snapshot(&db, "sibling-0").await == before_sibling,
        "a sibling that would have shifted must roll back too"
    );
    assert_eq!(
        seq(&db).await,
        before_seq,
        "the global sequence must not advance"
    );
    assert_eq!(
        decision_count(&db, "item-1").await,
        before_decisions,
        "decision history must be untouched"
    );
    assert_eq!(
        audit_count(&db).await,
        before_audit_count,
        "no audit event may survive a rolled-back mutation"
    );
}

#[tokio::test]
async fn clear_rolls_back_every_write_when_the_final_audit_insert_fails() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
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

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let before_item = item_snapshot(&db, "item-1").await;
    assert!(
        before_item.triage_override_reason.is_some(),
        "sanity: the reason column must be non-empty for rollback to actually exercise it"
    );
    let before_seq = seq(&db).await;
    let before_decisions = decision_count(&db, "item-1").await;
    let before_audit_count = audit_count(&db).await;

    query(
        "CREATE TRIGGER fail_triage_override_cleared_audit
         BEFORE INSERT ON audit_events
         WHEN NEW.kind = 'task_board.item.triage_override_cleared'
         BEGIN SELECT RAISE(ABORT, 'simulated triage override clear audit failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install audit failure trigger");

    db.clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
        item_id: "item-1".into(),
        actor: "operator-1".into(),
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect_err("a failed audit write must fail the whole clear");

    query("DROP TRIGGER fail_triage_override_cleared_audit")
        .execute(db.pool())
        .await
        .expect("remove audit failure trigger");

    assert!(
        item_snapshot(&db, "item-1").await == before_item,
        "the item's status/placement and the still-active override tuple must roll back byte-for-byte"
    );
    assert_eq!(
        seq(&db).await,
        before_seq,
        "the global sequence must not advance"
    );
    assert_eq!(
        decision_count(&db, "item-1").await,
        before_decisions,
        "decision history must be untouched"
    );
    assert_eq!(
        audit_count(&db).await,
        before_audit_count,
        "no audit event may survive a rolled-back mutation"
    );
}
