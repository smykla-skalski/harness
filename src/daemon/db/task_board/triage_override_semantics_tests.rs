use sqlx::query;

use super::super::super::items::{load_item_in_tx, replace_item_in_tx};
use super::super::super::triage_apply::apply_builtin_v1_triage_in_tx;
use super::super::{
    TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideSetInput,
    current_triage_override_in_tx,
};
use super::*;
use crate::daemon::db::TaskBoardLanePositionInput;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, OVERRIDE_PLACEMENT_PRODUCER, TaskBoardLaneOrigin,
    TaskBoardTriageEffectiveSource, TriageVerdict,
};

#[tokio::test]
async fn set_todo_promotes_a_backlog_item_with_ranked_placement() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: Some("looks ready".into()),
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("set override");

    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(result.item.lane_position, Some(0));
    let override_ = result.override_.expect("override present");
    assert_eq!(override_.verdict, TriageVerdict::Todo);
    assert_eq!(override_.actor, "operator-1");
    assert_eq!(override_.reason.as_deref(), Some("looks ready"));
    let effective = result.effective.expect("effective outcome");
    assert_eq!(effective.verdict, TriageVerdict::Todo);
    assert_eq!(effective.source, TaskBoardTriageEffectiveSource::Override);
}

#[tokio::test]
async fn set_undecided_demotes_an_automatically_placed_todo_item_to_backlog() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Undecided,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("set override");

    assert_eq!(result.item.status, TaskBoardStatus::Backlog);
    assert_eq!(result.item.lane_position, None);
    assert_eq!(result.item.lane_origin, None);
}

#[tokio::test]
async fn automatic_evaluation_keeps_deciding_but_never_moves_placement_while_overridden() {
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
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");

    // A later provider-sync-style re-evaluation (the same choke point
    // `apply_builtin_v1_triage_in_tx` that provider_exclusion.rs's restore
    // path calls) must still refresh the decision generation...
    let mut transaction = db
        .begin_immediate_transaction("re-evaluate while overridden")
        .await
        .expect("begin transaction");
    let (mut item, revision) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    let before_status = item.status;
    let before_lane_position = item.lane_position;
    item.tags = vec!["kind/bug".into()];
    let existing_override = current_triage_override_in_tx(&mut transaction, "item-1")
        .await
        .expect("read override");
    let outcome = apply_builtin_v1_triage_in_tx(
        &mut transaction,
        &mut item,
        "2026-07-23T01:00:00Z",
        false,
        existing_override.as_ref(),
    )
    .await
    .expect("apply triage")
    .expect("a fresh decision generation is still recorded");
    replace_item_in_tx(&mut transaction, &item, revision + 1)
        .await
        .expect("persist item");
    transaction.commit().await.expect("commit");

    // ...but must never apply its own placement effect while the override
    // stays active: the automatic verdict here is Todo (a meaningful label),
    // yet the item's placement must be untouched by this evaluation.
    assert_eq!(outcome.decision().verdict, TriageVerdict::Todo);
    assert_eq!(item.status, before_status);
    assert_eq!(item.lane_position, before_lane_position);
}

#[tokio::test]
async fn clear_reconciles_the_latest_automatic_decision_without_new_decision_history() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Undecided,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
    assert_eq!(
        db.task_board_triage_history("item-1", None, 10)
            .await
            .expect("history")
            .decisions
            .len(),
        1,
        "setting an override records no new decision history"
    );

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-2".into(),
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("clear override");

    assert!(result.override_.is_none());
    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(result.item.lane_position, Some(0));
    let effective = result.effective.expect("effective outcome");
    assert_eq!(effective.verdict, TriageVerdict::Todo);
    assert_eq!(effective.source, TaskBoardTriageEffectiveSource::Automatic);
    assert_eq!(
        db.task_board_triage_history("item-1", None, 10)
            .await
            .expect("history")
            .decisions
            .len(),
        1,
        "clearing an override reconciles the existing decision, it never invents a new one"
    );
    let payload = audit_payload(&db, "task_board.item.triage_override_cleared", "item-1").await;
    assert_eq!(payload["reconciled"], serde_json::json!(true));
}

/// An override is authoritative for lane outcome even over a manual anchor:
/// a manually anchored Todo item still demotes to Backlog when the override
/// says Undecided, not stuck at Todo just because a human placed it there.
/// The anchor itself survives the move -- only the lane it lives in changes.
#[tokio::test]
async fn set_undecided_override_moves_a_manually_anchored_todo_item_to_backlog() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    anchor_manually(&db, "item-1", 0).await;
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Undecided,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("override outranks a manual anchor for lane outcome");

    assert_eq!(result.item.status, TaskBoardStatus::Backlog);
    assert_eq!(result.item.lane_position, Some(0));
    match &result.item.lane_origin {
        Some(TaskBoardLaneOrigin::Manual { actor }) => assert_eq!(actor, "human-1"),
        other => panic!("expected the manual anchor to survive the lane move, got {other:?}"),
    }
}

/// The symmetric direction: a manually anchored Backlog item still promotes
/// to Todo when the override says Todo, not stuck in Backlog.
#[tokio::test]
async fn set_todo_override_moves_a_manually_anchored_backlog_item_to_todo() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1"))
        .await
        .expect("seed item");
    query(
        "UPDATE task_board_items SET
             status = 'backlog', lane_position = 0, lane_origin = 'manual',
             lane_actor = 'human-1', lane_set_at = '2026-07-23T00:00:00Z'
         WHERE item_id = 'item-1'",
    )
    .execute(db.pool())
    .await
    .expect("anchor item manually in backlog");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("override outranks a manual anchor for lane outcome");

    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(result.item.lane_position, Some(0));
    match &result.item.lane_origin {
        Some(TaskBoardLaneOrigin::Manual { actor }) => assert_eq!(actor, "human-1"),
        other => panic!("expected the manual anchor to survive the lane move, got {other:?}"),
    }
}

/// Clearing an override reconciles a manually anchored item against the
/// latest automatic decision exactly like a non-manual one -- the anchor's
/// actor and slot travel with it into whatever lane that decision implies.
#[tokio::test]
async fn clear_reconciles_a_manually_anchored_item_to_the_latest_decision() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Undecided,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");

    // A human anchors the item while the override is still active, in
    // whatever lane it currently sits (Backlog, per the override).
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: "item-1".into(),
        status: Some(TaskBoardStatus::Backlog),
        lane_position: 0,
        actor: "human-1".into(),
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("manual drag while overridden");

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-2".into(),
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("clear override");

    // The latest decision (seeded Todo) is still what clearing reconciles
    // to, even though the item is now manually anchored.
    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(result.item.lane_position, Some(0));
    match &result.item.lane_origin {
        Some(TaskBoardLaneOrigin::Manual { actor }) => assert_eq!(actor, "human-1"),
        other => panic!("expected the manual anchor to survive reconciliation, got {other:?}"),
    }
    let payload = audit_payload(&db, "task_board.item.triage_override_cleared", "item-1").await;
    assert_eq!(payload["reconciled"], serde_json::json!(true));
}

#[tokio::test]
async fn a_later_manual_position_change_does_not_clear_the_override() {
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
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_lane_position(TaskBoardLanePositionInput {
        item_id: "item-1".into(),
        status: Some(TaskBoardStatus::Todo),
        lane_position: 0,
        actor: "human-1".into(),
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("manual drag");

    let mut transaction = db
        .begin_immediate_transaction("read override after manual drag")
        .await
        .expect("begin transaction");
    let still_active = current_triage_override_in_tx(&mut transaction, "item-1")
        .await
        .expect("read override");
    transaction.commit().await.expect("commit");
    assert!(
        still_active.is_some(),
        "a manual position change must not clear an active override"
    );
}

async fn anchor_manually(db: &AsyncDaemonDb, item_id: &str, position: u32) {
    query(
        "UPDATE task_board_items SET
             status = 'todo', lane_position = ?2, lane_origin = 'manual',
             lane_actor = 'human-1', lane_set_at = '2026-07-23T00:00:00Z'
         WHERE item_id = ?1",
    )
    .bind(item_id)
    .bind(i64::from(position))
    .execute(db.pool())
    .await
    .expect("anchor item manually");
}

/// A set that merely agrees with a slot `BuiltInV1` already placed must not
/// steal credit for it -- the existing evaluator producer survives
/// untouched, exactly as if the override had never run.
#[tokio::test]
async fn set_agreeing_with_an_existing_builtin_placement_preserves_its_producer() {
    let (_directory, db) = connect().await;
    seed_decided_todo(&db, "item-1").await;
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;

    let result = db
        .set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
            item_id: "item-1".into(),
            verdict: TriageVerdict::Todo,
            actor: "operator-1".into(),
            reason: None,
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("set override agreeing with the existing placement");

    assert_eq!(
        result.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string()
        }),
        "an agreeing override must not overwrite BuiltInV1's own provenance"
    );
}

/// Clearing must never leave a slot claiming the override's producer once
/// the override itself is gone, even when the slot's lane and rank do not
/// change -- the real evaluator identity always wins on clear.
#[tokio::test]
async fn clear_replaces_an_override_attributed_producer_with_builtin() {
    let (_directory, db) = connect().await;
    let mut item = backlog_item("item-1");
    item.tags = vec!["kind/bug".into()];
    db.create_task_board_item(item).await.expect("seed item");
    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
    assert_eq!(
        revision(&db, "item-1").await,
        expected_item_revision + 1,
        "sanity: the set actually wrote the row"
    );

    let expected_item_revision = revision(&db, "item-1").await;
    let expected_items_change_seq = seq(&db).await;
    let result = db
        .clear_task_board_triage_override(TaskBoardTriageOverrideClearInput {
            item_id: "item-1".into(),
            actor: "operator-2".into(),
            expected_item_revision,
            expected_items_change_seq,
        })
        .await
        .expect("clear override");

    assert_eq!(result.item.status, TaskBoardStatus::Todo);
    assert_eq!(
        result.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string()
        }),
        "clearing must restamp an override-attributed slot to the real evaluator, not leave it \
         claiming a producer that no longer exists"
    );
    assert_ne!(
        result.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        })
    );
}
