use sqlx::query_scalar;
use tempfile::tempdir;

use super::super::{TaskBoardLanePositionInput, TaskBoardLaneResetInput};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    TaskBoardItem, TaskBoardLaneOrigin, TaskBoardPriority, TaskBoardStatus, TaskBoardSyncStore,
    build_dispatch_plans_with_policy,
};

#[tokio::test]
async fn explicit_slots_shift_collisions_then_reset_and_tombstone_compacts() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    db.create_task_board_item(item("b", "2026-07-22T10:01:00Z"))
        .await
        .expect("create b");
    let first = db.task_board_items_snapshot(None).await.expect("snapshot");
    let a_revision = revision(&first, "a");
    let manual_a = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: None,
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: a_revision,
            expected_items_change_seq: first.items_change_seq,
        })
        .await
        .expect("anchor a");
    assert_eq!(manual_a.item.lane_position, Some(0));

    let second = db.task_board_items_snapshot(None).await.expect("snapshot");
    let collision = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "b".into(),
            status: None,
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&second, "b"),
            expected_items_change_seq: second.items_change_seq,
        })
        .await
        .expect("shift a for b");
    assert_eq!(collision.item.lane_position, Some(0));
    assert_eq!(collision.shifted.len(), 1);
    assert_eq!(collision.shifted[0].item_id, "a");
    let shifted = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_positions(&shifted, &["b", "a"]);
    assert_eq!(item_from(&shifted, "a").lane_position, Some(1));

    let reset = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "b".into(),
            actor: "control-user".into(),
            expected_item_revision: revision(&shifted, "b"),
            expected_items_change_seq: shifted.items_change_seq,
        })
        .await
        .expect("reset b");
    assert_eq!(reset.item.lane_position, None);
    let reset_snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_positions(&reset_snapshot, &["a", "b"]);
    assert_eq!(item_from(&reset_snapshot, "a").lane_position, Some(0));

    db.delete_task_board_item("a").await.expect("tombstone a");
    let live = db
        .task_board_items_snapshot(None)
        .await
        .expect("live snapshot");
    assert_positions(&live, &["b"]);
    let tombstone = db.task_board_item("a").await.expect("tombstone");
    assert_eq!(tombstone.lane_position, None);
    assert_eq!(tombstone.lane_origin, None);
    assert_eq!(tombstone.lane_set_at, None);
}

#[tokio::test]
async fn removing_a_default_card_compacts_an_explicit_source_anchor_once() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("default", "2026-07-22T10:00:00Z"))
        .await
        .expect("create default card");
    db.create_task_board_item(item("anchor", "2026-07-22T10:01:00Z"))
        .await
        .expect("create anchored card");
    anchor(&db, "anchor", 1).await;
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let invalid = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "default".into(),
            status: None,
            lane_position: 9,
            actor: "control-user".into(),
            expected_item_revision: revision(&before, "default"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect_err("invalid destination slot");
    assert!(invalid.to_string().contains("capacity"));
    let after_rejection = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after_rejection.items_change_seq, before.items_change_seq);
    assert_eq!(
        revision(&after_rejection, "anchor"),
        revision(&before, "anchor")
    );
    assert_eq!(item_from(&after_rejection, "anchor").lane_position, Some(1));

    db.delete_task_board_item("default")
        .await
        .expect("tombstone default card");
    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after.items_change_seq, before.items_change_seq + 1);
    assert_eq!(item_from(&after, "anchor").lane_position, Some(0));
    assert_eq!(revision(&after, "anchor"), revision(&before, "anchor") + 1);
    let audit_sequence: i64 = query_scalar(
        "SELECT json_extract(payload_json, '$.items_change_seq') FROM audit_events
         WHERE subject = ?1 AND kind = 'task_board.item.lane_position_changed'",
    )
    .bind("default")
    .fetch_one(db.pool())
    .await
    .expect("compaction audit");
    assert_eq!(audit_sequence, after.items_change_seq);
}

#[tokio::test]
async fn generic_cross_lane_move_preserves_an_explicit_slot_and_manual_wins_over_automatic() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: "a".into(),
        status: None,
        lane_position: 0,
        actor: "control-user".into(),
        expected_item_revision: revision(&snapshot, "a"),
        expected_items_change_seq: snapshot.items_change_seq,
    })
    .await
    .expect("anchor a");
    let anchored = db.task_board_item("a").await.expect("anchored item");
    let synced = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
        &db,
        &anchored,
        TaskBoardItemPatch {
            title: Some("Provider title".into()),
            ..TaskBoardItemPatch::default()
        },
    )
    .await
    .expect("provider update");
    assert_eq!(synced.lane_position, Some(0));
    assert!(matches!(
        synced.lane_origin,
        Some(TaskBoardLaneOrigin::Manual { .. })
    ));
    db.create_task_board_item(item("automatic", "2026-07-22T10:01:00Z"))
        .await
        .expect("create automatic item");
    let automatic = db
        .place_task_board_item_automatically("automatic", 0, "provider-sync".into())
        .await
        .expect("automatic placement")
        .expect("automatic placement result");
    assert_eq!(automatic.item.lane_position, Some(1));
    let repeated = db
        .place_task_board_item_automatically("automatic", 0, "provider-sync".into())
        .await
        .expect("repeat automatic placement")
        .expect("automatic placement result");
    assert_eq!(repeated.item.lane_position, Some(1));
    assert_eq!(
        db.task_board_item("a")
            .await
            .expect("manual anchor")
            .lane_position,
        Some(0)
    );
    db.update_task_board_item("a", |item| {
        item.status = TaskBoardStatus::Done;
        Ok(true)
    })
    .await
    .expect("move lane");
    let moved = db.task_board_item("a").await.expect("moved item");
    assert_eq!(moved.status, TaskBoardStatus::Done);
    assert_eq!(moved.lane_position, Some(0));
    assert!(matches!(
        moved.lane_origin,
        Some(TaskBoardLaneOrigin::Manual { .. })
    ));
    assert!(
        db.place_task_board_item_automatically("a", 0, "provider-sync".into())
            .await
            .expect("automatic placement")
            .is_none()
    );
}

#[tokio::test]
async fn cross_lane_position_transition_runs_terminal_dispatch_cleanup() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("active", "2026-07-22T10:00:00Z"))
        .await
        .expect("create active item");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let lifecycle = build_dispatch_plans_with_policy(
        &[item_from(&snapshot, "active").clone()],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &std::collections::HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch("active", "session", "work", &lifecycle)
        .await
        .expect("activate item");
    let active = db
        .task_board_items_snapshot(None)
        .await
        .expect("active snapshot");
    let moved = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "active".into(),
            status: Some(TaskBoardStatus::Done),
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&active, "active"),
            expected_items_change_seq: active.items_change_seq,
        })
        .await
        .expect("terminal cross-lane placement");
    assert_eq!(moved.item.status, TaskBoardStatus::Done);
    let dispatch_status: String =
        query_scalar("SELECT status FROM task_board_dispatch_intents WHERE item_id = ?1")
            .bind("active")
            .fetch_one(db.pool())
            .await
            .expect("terminal dispatch state");
    assert_eq!(dispatch_status, "failed");
    let active_admissions: i64 = query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id IN (SELECT intent_id FROM task_board_dispatch_intents WHERE item_id = ?1)
           AND state IN ('reserved', 'committed')",
    )
    .bind("active")
    .fetch_one(db.pool())
    .await
    .expect("active admissions");
    assert_eq!(
        active_admissions, 0,
        "terminal move leaves no live admission"
    );
}

#[tokio::test]
async fn stale_cas_and_malformed_provenance_leave_the_sequence_and_rows_unchanged() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: None,
            lane_position: 0,
            actor: String::new(),
            expected_item_revision: revision(&before, "a"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect_err("empty actor must fail before commit");
    assert!(error.to_string().contains("lane"));
    let after_invalid = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after_invalid.items_change_seq, before.items_change_seq);
    assert_eq!(item_from(&after_invalid, "a").lane_position, None);

    db.update_task_board_item("a", |item| {
        item.title = "changed".into();
        Ok(true)
    })
    .await
    .expect("unrelated change");
    let stale = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control-user".into(),
            expected_item_revision: revision(&before, "a"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect_err("stale snapshot must fail");
    assert!(stale.to_string().contains("concurrently"));
}

#[tokio::test]
async fn explicit_position_requires_the_current_lane_cardinality() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: None,
            lane_position: u32::MAX,
            actor: "control-user".into(),
            expected_item_revision: revision(&snapshot, "a"),
            expected_items_change_seq: snapshot.items_change_seq,
        })
        .await
        .expect_err("position beyond lane cardinality must fail");
    assert!(error.to_string().contains("capacity"));
}

#[tokio::test]
async fn create_rejects_an_explicit_position_outside_the_live_lane_cardinality() {
    let (_directory, db) = connect().await;
    let mut out_of_range = item("out-of-range", "2026-07-22T10:00:00Z");
    out_of_range.lane_position = Some(u32::MAX);
    out_of_range.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "control-user".into(),
    });
    out_of_range.lane_set_at = Some("2026-07-22T10:00:00Z".into());
    let error = db
        .create_task_board_item(out_of_range)
        .await
        .expect_err("out-of-range explicit create must fail");
    assert!(error.to_string().contains("capacity"));
}

#[tokio::test]
async fn reorder_invalidates_a_todo_pick_snapshot_before_dispatch_can_return_it() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    db.create_task_board_item(item("b", "2026-07-22T10:01:00Z"))
        .await
        .expect("create b");
    let picked = db
        .task_board_items_snapshot(Some(TaskBoardStatus::Todo))
        .await
        .expect("pick snapshot");
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: "b".into(),
        status: None,
        lane_position: 0,
        actor: "control-user".into(),
        expected_item_revision: revision(&picked, "b"),
        expected_items_change_seq: picked.items_change_seq,
    })
    .await
    .expect("concurrent reorder");
    assert!(
        !db.task_board_item_snapshot_is_current(
            "a",
            revision(&picked, "a"),
            picked.items_change_seq,
        )
        .await
        .expect("revalidate pick"),
        "pick must retry after another card reorders the Todo lane"
    );
}

#[tokio::test]
async fn dispatch_transitions_shift_anchors_once_and_emit_one_audit_per_transition() {
    let (_directory, db) = connect().await;
    for (id, created_at) in [("a", "2026-07-22T10:00:00Z"), ("b", "2026-07-22T10:01:00Z")] {
        db.create_task_board_item(item(id, created_at))
            .await
            .expect("create item");
    }
    anchor(&db, "a", 0).await;
    anchor(&db, "b", 0).await;
    let before_dispatch = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_positions(&before_dispatch, &["b", "a"]);
    let lifecycle = build_dispatch_plans_with_policy(
        &[item_from(&before_dispatch, "b").clone()],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &std::collections::HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch("b", "session-b", "work-b", &lifecycle)
        .await
        .expect("todo to in-progress");
    let after_dispatch = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(
        after_dispatch.items_change_seq,
        before_dispatch.items_change_seq + 1
    );
    assert_eq!(item_from(&after_dispatch, "a").lane_position, Some(0));
    let claim = db
        .claim_task_board_dispatch("b")
        .await
        .expect("claim")
        .expect("pending dispatch");
    db.fail_task_board_dispatch(&claim.intent_id, &claim.claim_token, None, "failed")
        .await
        .expect("failure rollback");
    let after_failure = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(
        after_failure.items_change_seq,
        after_dispatch.items_change_seq + 1
    );
    assert_positions(&after_failure, &["b", "a"]);
    assert_eq!(item_from(&after_failure, "b").lane_position, Some(0));
    assert_eq!(item_from(&after_failure, "a").lane_position, Some(1));
    assert!(revision(&after_failure, "a") > revision(&before_dispatch, "a"));
    let audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE subject = ?1 AND kind = 'task_board.item.lane_position_changed'",
    )
    .bind("b")
    .fetch_one(db.pool())
    .await
    .expect("lane audits");
    assert_eq!(audits, 2, "dispatch and rollback each audit once");
    let position_sets: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE subject = ?1 AND kind = 'task_board.item.position_set'",
    )
    .bind("b")
    .fetch_one(db.pool())
    .await
    .expect("position set audit");
    assert_eq!(
        position_sets, 1,
        "manual set emits one semantic audit event"
    );
}

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("database");
    (directory, db)
}

fn item(id: &str, created_at: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(id.into(), id.into(), String::new(), created_at.into());
    item.priority = TaskBoardPriority::Medium;
    item
}

async fn anchor(db: &AsyncDaemonDb, item_id: &str, lane_position: u32) {
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: item_id.into(),
        status: None,
        lane_position,
        actor: "control-user".into(),
        expected_item_revision: revision(&snapshot, item_id),
        expected_items_change_seq: snapshot.items_change_seq,
    })
    .await
    .expect("anchor item");
}

fn revision(snapshot: &super::lane_order::TaskBoardItemsSnapshot, id: &str) -> i64 {
    snapshot
        .items
        .iter()
        .find(|item| item.item.id == id)
        .expect("item in snapshot")
        .item_revision
}

fn item_from<'a>(
    snapshot: &'a super::lane_order::TaskBoardItemsSnapshot,
    id: &str,
) -> &'a TaskBoardItem {
    &snapshot
        .items
        .iter()
        .find(|item| item.item.id == id)
        .expect("item in snapshot")
        .item
}

fn assert_positions(snapshot: &super::lane_order::TaskBoardItemsSnapshot, expected: &[&str]) {
    assert_eq!(
        snapshot
            .items
            .iter()
            .map(|item| item.item.id.as_str())
            .collect::<Vec<_>>(),
        expected
    );
}

#[path = "lane_order_regression_tests.rs"]
mod regressions;

#[path = "lane_order_position_contract_tests.rs"]
mod position_contracts;

#[path = "lane_order_revision_overflow_tests.rs"]
mod revision_overflow;
