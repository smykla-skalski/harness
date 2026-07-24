use super::super::{TaskBoardTriageOverrideSetInput, current_triage_override_in_tx};
use super::*;
use crate::daemon::db::TaskBoardLanePositionInput;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, OVERRIDE_PLACEMENT_PRODUCER, TaskBoardLaneOrigin,
    TaskBoardPriority, TriageVerdict,
};

async fn seed_with_override(db: &AsyncDaemonDb, item_id: &str, verdict: TriageVerdict) {
    db.create_task_board_item(backlog_item(item_id))
        .await
        .expect("seed item");
    let expected_item_revision = revision(db, item_id).await;
    let expected_items_change_seq = seq(db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: item_id.into(),
        verdict,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
}

#[tokio::test]
async fn human_update_rejects_a_status_write_conflicting_with_a_todo_override() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;

    let error = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Backlog;
            Ok(true)
        })
        .await
        .expect_err("a status write away from the override's lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);
    assert_eq!(seq(&db).await, before_seq);
}

#[tokio::test]
async fn human_update_rejects_a_status_write_conflicting_with_an_undecided_override() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Undecided).await;
    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;

    let error = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            Ok(true)
        })
        .await
        .expect_err("a status write away from the override's lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);
    assert_eq!(seq(&db).await, before_seq);
}

#[tokio::test]
async fn human_update_allows_a_status_write_agreeing_with_the_override() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;

    let mutation = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            item.priority = TaskBoardPriority::High;
            Ok(true)
        })
        .await
        .expect("a same-lane write is allowed")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
    assert_eq!(mutation.item.priority, TaskBoardPriority::High);
}

#[tokio::test]
async fn human_update_with_nothing_to_rerank_does_not_churn_placement() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let before_revision = revision(&db, "item-1").await;

    let mutation = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.priority = TaskBoardPriority::Low;
            Ok(true)
        })
        .await
        .expect("a non-placement write is never rejected")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
    assert_eq!(mutation.item.priority, TaskBoardPriority::Low);
    assert_eq!(
        mutation.item.lane_position,
        Some(0),
        "alone in Todo, nothing to rerank around"
    );
    assert_eq!(mutation.item_revision, before_revision + 1);
}

/// A non-manual override's rank must track priority even when only a
/// `HumanUpdate` field (not status) changes. Anchors the Manual item first,
/// through the collision-safe position API, so live rows never collide on
/// `(status, lane_position)`.
#[tokio::test]
async fn human_update_reranks_a_nonmanual_todo_override_around_a_manual_anchor() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("anchor"))
        .await
        .expect("seed anchor");
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: "anchor".into(),
        status: Some(TaskBoardStatus::Todo),
        lane_position: 0,
        actor: "human-1".into(),
        expected_item_revision: revision(&db, "anchor").await,
        expected_items_change_seq: seq(&db).await,
    })
    .await
    .expect("anchor via the position API");

    let mut sibling = backlog_item("sibling");
    sibling.status = TaskBoardStatus::Todo;
    sibling.priority = TaskBoardPriority::High;
    sibling.lane_position = Some(1);
    sibling.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string(),
    });
    sibling.lane_set_at = Some("2026-07-23T00:00:00Z".into());
    db.create_task_board_item(sibling)
        .await
        .expect("seed higher-priority sibling");

    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let after_set = db
        .find_task_board_item("item-1")
        .await
        .expect("read item")
        .expect("exists");
    assert_eq!(
        after_set.lane_position,
        Some(2),
        "ranks after the anchor and the sibling"
    );
    let sibling_revision = revision(&db, "sibling").await;

    let mutation = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.priority = TaskBoardPriority::Critical;
            Ok(true)
        })
        .await
        .expect("a non-placement write is never rejected")
        .expect("mutation applied");
    assert_eq!(
        mutation.item.lane_position,
        Some(1),
        "must reflow above the now-lower-priority sibling, still below the fixed anchor"
    );
    assert_eq!(
        mutation.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        })
    );
    assert_eq!(
        revision(&db, "sibling").await,
        sibling_revision + 1,
        "the sibling was shifted"
    );
    let anchor = db
        .find_task_board_item("anchor")
        .await
        .expect("read anchor")
        .expect("exists");
    assert_eq!(
        anchor.lane_position,
        Some(0),
        "the manual anchor's slot is never touched"
    );
}

/// The same reassert applies to an internal-workflow (`None` ingress)
/// return to a triage lane -- e.g. a planning approval landing on Todo --
/// not only `HumanUpdate`.
#[tokio::test]
async fn internal_workflow_return_reasserts_override_rank_and_producer() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    db.update_task_board_item("item-1", |item| {
        item.status = TaskBoardStatus::Planning;
        Ok(true)
    })
    .await
    .expect("a lifecycle exit to a non-triage status is always allowed")
    .expect("mutation applied");

    let mutation = db
        .update_task_board_item("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            Ok(true)
        })
        .await
        .expect("an agreeing internal return to a triage lane is allowed")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
    assert_eq!(mutation.item.lane_position, Some(0));
    assert_eq!(
        mutation.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        }),
        "the override's own producer must be reasserted, not left stale from before the exit"
    );
}

#[tokio::test]
async fn provider_reconcile_reapplies_a_todo_override_after_a_conflicting_status_write() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;

    let mutation = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.status = TaskBoardStatus::Backlog;
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(
        mutation.item.status,
        TaskBoardStatus::Todo,
        "the active override's lane must survive a conflicting provider write"
    );

    let mut transaction = db
        .begin_immediate_transaction("read override after provider reconcile")
        .await
        .expect("begin transaction");
    let still_active = current_triage_override_in_tx(&mut transaction, "item-1")
        .await
        .expect("read override");
    transaction.commit().await.expect("commit");
    assert!(
        still_active.is_some(),
        "reasserting the lane must not itself clear the override"
    );
}

#[tokio::test]
async fn provider_reconcile_reapplies_an_undecided_override_after_a_conflicting_status_write() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Undecided).await;

    let mutation = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(
        mutation.item.status,
        TaskBoardStatus::Backlog,
        "the active override's lane must survive a conflicting provider write"
    );
}

#[tokio::test]
async fn provider_reconcile_does_not_force_a_terminal_status_back_into_a_triage_lane() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;

    let mutation = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.status = TaskBoardStatus::Done;
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(
        mutation.item.status,
        TaskBoardStatus::Done,
        "a legitimate move out of the triage lanes is never forced back"
    );
}

#[tokio::test]
async fn provider_reconcile_with_no_status_change_does_not_churn_placement() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    let before_revision = revision(&db, "item-1").await;

    let mutation = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.priority = TaskBoardPriority::Low;
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
    assert_eq!(mutation.item_revision, before_revision + 1);
}

/// The override governs Backlog-versus-Todo placement only -- an ordinary
/// human exit to a non-triage lifecycle status must never be blocked just
/// because a triage override happens to be active.
#[tokio::test]
async fn human_update_allows_a_terminal_exit_while_overridden() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;

    let mutation = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Done;
            Ok(true)
        })
        .await
        .expect("a terminal exit is never blocked by an active override")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Done);

    let mut transaction = db
        .begin_immediate_transaction("read override after terminal exit")
        .await
        .expect("begin transaction");
    let still_active = current_triage_override_in_tx(&mut transaction, "item-1")
        .await
        .expect("read override");
    transaction.commit().await.expect("commit");
    assert!(
        still_active.is_some(),
        "a terminal exit leaves the override dormant, not cleared"
    );
}

/// Once an item returns to a triage lane, the override is enforced again:
/// a conflicting return is rejected, an agreeing one is allowed.
#[tokio::test]
async fn human_update_enforces_the_override_again_on_return_to_a_triage_lane() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    db.update_task_board_item_with_triage("item-1", |item| {
        item.status = TaskBoardStatus::Done;
        Ok(true)
    })
    .await
    .expect("terminal exit")
    .expect("mutation applied");

    let before_revision = revision(&db, "item-1").await;
    let error = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Backlog;
            Ok(true)
        })
        .await
        .expect_err("a conflicting return to a triage lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);

    let mutation = db
        .update_task_board_item_with_triage("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            Ok(true)
        })
        .await
        .expect("an agreeing return to a triage lane is allowed")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
}

/// `update_task_board_item` (ingress `None`) is the internal choke point
/// every workflow mutation shares -- planning approval included. It must
/// enforce the override too, atomically, not just the public update API.
#[tokio::test]
async fn internal_workflow_write_rejects_a_conflicting_return_to_a_triage_lane() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Undecided).await;
    db.update_task_board_item("item-1", |item| {
        item.status = TaskBoardStatus::Planning;
        Ok(true)
    })
    .await
    .expect("a lifecycle exit to a non-triage status is always allowed")
    .expect("mutation applied");

    let before_revision = revision(&db, "item-1").await;
    let before_seq = seq(&db).await;
    let before_audit_count = audit_count(&db).await;
    let error = crate::daemon::service::approve_task_board_plan_db(
        &db,
        &crate::daemon::protocol::TaskBoardPlanApproveRequest {
            id: "item-1".into(),
            approved_by: "lead-1".into(),
            approved_at: None,
        },
    )
    .await
    .expect_err("a real plan approval returning to a conflicting triage lane is rejected");
    assert!(error.to_string().contains("triage override"));
    assert_eq!(revision(&db, "item-1").await, before_revision);
    assert_eq!(seq(&db).await, before_seq);
    assert_eq!(audit_count(&db).await, before_audit_count);
    let retained = db
        .find_task_board_item("item-1")
        .await
        .expect("read item")
        .expect("item exists");
    assert_eq!(
        retained.status,
        TaskBoardStatus::Planning,
        "the rejected approval must never move the item"
    );
    assert!(
        retained.planning.approved_by.is_none(),
        "the whole approval mutation must roll back, not just the status field"
    );
}

#[tokio::test]
async fn internal_workflow_write_allows_an_agreeing_return_to_a_triage_lane() {
    let (_directory, db) = connect().await;
    seed_with_override(&db, "item-1", TriageVerdict::Todo).await;
    db.update_task_board_item("item-1", |item| {
        item.status = TaskBoardStatus::Planning;
        Ok(true)
    })
    .await
    .expect("a lifecycle exit to a non-triage status is always allowed")
    .expect("mutation applied");

    let mutation = db
        .update_task_board_item("item-1", |item| {
            item.status = TaskBoardStatus::Todo;
            Ok(true)
        })
        .await
        .expect("an agreeing internal return to a triage lane is allowed")
        .expect("mutation applied");
    assert_eq!(mutation.item.status, TaskBoardStatus::Todo);
}
