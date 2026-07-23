use super::super::TriageOutcome;
use super::{
    apply_builtin_v1_triage_in_tx, backlog_item, connect, load_item_in_tx, replace_item_in_tx,
    seed_decided_todo_item,
};
use crate::task_board::{BUILTIN_V1_EVALUATOR_IDENTITY, TaskBoardLaneOrigin, TaskBoardStatus};

#[tokio::test]
async fn same_evidence_with_missing_builtin_placement_reapplies_and_reports_retained_effect() {
    let (_directory, db) = connect().await;
    let item_id = seed_decided_todo_item(&db).await;

    let mut transaction = db
        .begin_immediate_transaction("test missing placement")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, item_id)
        .await
        .expect("load item")
        .expect("item exists");
    // A valid default Todo item has no placement at all yet, not a partial
    // tuple `validate_item` would reject (`lane_position` absent while
    // `lane_origin` is still set).
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T02:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("desync must be reported");
    transaction.commit().await.expect("commit");

    assert!(matches!(outcome, TriageOutcome::RetainedEffect(_)));
    assert_eq!(item.lane_position, Some(0));
}

#[tokio::test]
async fn same_evidence_with_wrong_automatic_producer_reapplies_and_reports_retained_effect() {
    let (_directory, db) = connect().await;
    let item_id = seed_decided_todo_item(&db).await;

    let mut transaction = db
        .begin_immediate_transaction("test wrong producer")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, item_id)
        .await
        .expect("load item")
        .expect("item exists");
    item.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: "some-other-evaluator".into(),
    });
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T02:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("desync must be reported");
    transaction.commit().await.expect("commit");

    assert!(matches!(outcome, TriageOutcome::RetainedEffect(_)));
    assert_eq!(
        item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string()
        })
    );
}

#[tokio::test]
async fn same_evidence_with_stale_backlog_placement_reports_retained_effect() {
    let (_directory, db) = connect().await;
    // No meaningful labels -> the fresh decision is genuinely Undecided.
    db.create_task_board_item(backlog_item("item-1", Vec::new()))
        .await
        .expect("seed item");
    let mut first_transaction = db
        .begin_immediate_transaction("seed undecided")
        .await
        .expect("begin transaction");
    let (mut item, revision) = load_item_in_tx(&mut first_transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    apply_builtin_v1_triage_in_tx(
        &mut first_transaction,
        &mut item,
        "2026-07-22T01:00:00Z",
        false,
    )
    .await
    .expect("apply triage")
    .expect("decision recorded");
    replace_item_in_tx(&mut first_transaction, &item, revision + 1)
        .await
        .expect("persist");
    first_transaction.commit().await.expect("commit first");

    // Simulate a leftover placement artifact on an item whose decision and
    // status both already say Backlog/Undecided.
    let mut transaction = db
        .begin_immediate_transaction("test stale backlog placement")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    // A complete, otherwise-valid Automatic Todo tuple `validate_item` would
    // accept, just stale relative to the item's actual Backlog/Undecided
    // status and decision -- not a partial position-only tuple.
    item.lane_position = Some(3);
    item.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string(),
    });
    item.lane_set_at = Some("2026-07-22T01:30:00Z".into());
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T02:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("desync must be reported");
    transaction.commit().await.expect("commit");

    assert!(matches!(outcome, TriageOutcome::RetainedEffect(_)));
}

#[tokio::test]
async fn human_suppressed_status_move_produces_no_retained_effect_audit() {
    let (_directory, db) = connect().await;
    let item_id = seed_decided_todo_item(&db).await;

    let mut transaction = db
        .begin_immediate_transaction("test suppressed move")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, item_id)
        .await
        .expect("load item")
        .expect("item exists");
    // Models the real items.rs update path: a direct human status move to
    // Backlog already clears the complete placement tuple (see
    // `clear_stale_automatic_placement_on_human_status_move`) before triage
    // ever runs.
    item.status = TaskBoardStatus::Backlog;
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T02:00:00Z", true)
            .await
            .expect("apply triage");
    transaction.commit().await.expect("commit");

    assert!(
        outcome.is_none(),
        "a suppressed direct effect must never report a retained-effect outcome"
    );
}

#[tokio::test]
async fn manual_anchor_produces_no_retained_effect_audit_on_a_later_pass() {
    let (_directory, db) = connect().await;
    let mut manual = backlog_item("item-1", Vec::new());
    manual.status = TaskBoardStatus::Todo;
    manual.lane_position = Some(0);
    manual.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "person".into(),
    });
    manual.lane_set_at = Some("2026-07-22T00:00:00Z".into());
    db.create_task_board_item(manual)
        .await
        .expect("seed manually placed item");

    let mut first_transaction = db
        .begin_immediate_transaction("test manual first pass")
        .await
        .expect("begin transaction");
    let (mut item, revision) = load_item_in_tx(&mut first_transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    apply_builtin_v1_triage_in_tx(
        &mut first_transaction,
        &mut item,
        "2026-07-22T01:00:00Z",
        false,
    )
    .await
    .expect("apply triage")
    .expect("decision recorded even though placement is suppressed");
    replace_item_in_tx(&mut first_transaction, &item, revision + 1)
        .await
        .expect("persist");
    first_transaction.commit().await.expect("commit first");

    let mut second_transaction = db
        .begin_immediate_transaction("test manual second pass")
        .await
        .expect("begin transaction");
    let (mut reloaded, _) = load_item_in_tx(&mut second_transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    let outcome = apply_builtin_v1_triage_in_tx(
        &mut second_transaction,
        &mut reloaded,
        "2026-07-22T02:00:00Z",
        false,
    )
    .await
    .expect("apply triage");
    second_transaction.commit().await.expect("commit second");

    assert!(
        outcome.is_none(),
        "a manual anchor must never report a retained-effect outcome"
    );
}
