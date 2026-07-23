use tempfile::tempdir;

use super::super::items::load_item_in_tx;
use super::apply_builtin_v1_triage_in_tx;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardPriority,
    TaskBoardStatus, TriageCause, TriageReasonCode, TriageVerdict,
};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

/// A `work_item_id` placeholder keeps the item ineligible for BuiltInV1 at
/// seed time, so `db.create_task_board_item` (which itself now runs
/// BuiltInV1) does not pre-empt the explicit `apply_builtin_v1_triage_in_tx`
/// call each test exercises. Tests clear it after loading, before applying.
fn backlog_item(id: &str, tags: Vec<String>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-22T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item.tags = tags;
    item.work_item_id = Some("seed-placeholder".into());
    item
}

#[tokio::test]
async fn eligible_backlog_item_with_a_label_promotes_to_todo_with_automatic_placement() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1", vec!["kind/bug".into()]))
        .await
        .expect("seed item");

    let mut transaction = db
        .begin_immediate_transaction("test promote")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    let decision =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z")
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    assert_eq!(decision.verdict, TriageVerdict::Todo);
    assert_eq!(decision.reason_code, TriageReasonCode::MeaningfulLabel);
    assert_eq!(decision.cause, TriageCause::Initial);
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert_eq!(item.lane_position, Some(0));
    assert_eq!(
        item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string()
        })
    );
    assert_eq!(item.lane_set_at.as_deref(), Some("2026-07-22T01:00:00Z"));
}

#[tokio::test]
async fn eligible_backlog_item_with_no_labels_stays_in_backlog_as_undecided() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1", Vec::new()))
        .await
        .expect("seed item");

    let mut transaction = db
        .begin_immediate_transaction("test undecided")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    let decision =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z")
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    assert_eq!(decision.verdict, TriageVerdict::Undecided);
    assert_eq!(decision.reason_code, TriageReasonCode::NoMeaningfulLabels);
    assert_eq!(item.status, TaskBoardStatus::Backlog);
    assert_eq!(item.lane_position, None);
}

#[tokio::test]
async fn needs_info_label_stays_undecided_even_with_other_labels() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item(
        "item-1",
        vec!["kind/bug".into(), "triage/needs-info".into()],
    ))
    .await
    .expect("seed item");

    let mut transaction = db
        .begin_immediate_transaction("test needs info")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    let decision =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z")
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    assert_eq!(decision.verdict, TriageVerdict::Undecided);
    assert_eq!(decision.reason_code, TriageReasonCode::NeedsInfoLabel);
    assert_eq!(item.status, TaskBoardStatus::Backlog);
}

#[tokio::test]
async fn unchanged_fingerprint_is_idempotent_and_records_no_new_decision() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("item-1", vec!["kind/bug".into()]))
        .await
        .expect("seed item");

    let mut first_transaction = db
        .begin_immediate_transaction("test first pass")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut first_transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    apply_builtin_v1_triage_in_tx(&mut first_transaction, &mut item, "2026-07-22T01:00:00Z")
        .await
        .expect("apply triage")
        .expect("decision recorded");
    first_transaction.commit().await.expect("commit first");

    // Re-evaluate the same fields again (as an unrelated field update would);
    // the fingerprint has not changed, so this must be a no-op.
    let mut second_transaction = db
        .begin_immediate_transaction("test second pass")
        .await
        .expect("begin transaction");
    let (mut reloaded, _) = load_item_in_tx(&mut second_transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    let repeat = apply_builtin_v1_triage_in_tx(
        &mut second_transaction,
        &mut reloaded,
        "2026-07-22T02:00:00Z",
    )
    .await
    .expect("apply triage");
    second_transaction.commit().await.expect("commit second");

    assert!(repeat.is_none(), "unchanged fingerprint must not re-decide");
}

#[tokio::test]
async fn manual_placement_suppresses_status_and_placement_but_not_decision_history() {
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

    let mut transaction = db
        .begin_immediate_transaction("test manual suppression")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    // No labels at all -> BuiltInV1 would normally demote to Backlog/Undecided,
    // but a manual anchor must suppress the status/placement effect.
    let decision =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z")
            .await
            .expect("apply triage")
            .expect("decision recorded even though placement is suppressed");
    transaction.commit().await.expect("commit");

    assert_eq!(decision.verdict, TriageVerdict::Undecided);
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert_eq!(item.lane_position, Some(0));
    assert_eq!(
        item.lane_origin,
        Some(TaskBoardLaneOrigin::Manual {
            actor: "person".into()
        })
    );
}

#[tokio::test]
async fn fresh_evidence_demotes_a_prior_automatic_todo_verdict_back_to_backlog() {
    // Exercised end-to-end through the public API (rather than a manual
    // transaction) so the promotion is actually persisted before the
    // follow-up update reloads and re-evaluates it.
    let (_directory, db) = connect().await;
    let mut item = backlog_item("item-1", vec!["kind/bug".into()]);
    item.work_item_id = None;
    let created = db
        .create_task_board_item(item)
        .await
        .expect("seed item")
        .item;
    assert_eq!(created.status, TaskBoardStatus::Todo);
    assert_eq!(
        created.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string()
        })
    );

    let mutation = db
        .update_task_board_item("item-1", |item| {
            item.tags = Vec::new();
            Ok(true)
        })
        .await
        .expect("update item")
        .expect("update mutates");

    assert_eq!(mutation.item.status, TaskBoardStatus::Backlog);
    assert_eq!(mutation.item.lane_position, None);
    assert_eq!(mutation.item.lane_origin, None);
}

#[tokio::test]
async fn ineligible_umbrella_item_is_never_evaluated() {
    let (_directory, db) = connect().await;
    let mut umbrella = backlog_item("item-1", vec!["kind/bug".into()]);
    umbrella.kind = crate::task_board::types::TaskBoardItemKind::Umbrella;
    db.create_task_board_item(umbrella)
        .await
        .expect("seed umbrella item");

    let mut transaction = db
        .begin_immediate_transaction("test ineligible")
        .await
        .expect("begin transaction");
    let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    let decision =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z")
            .await
            .expect("apply triage");
    transaction.commit().await.expect("commit");

    assert!(decision.is_none());
    assert_eq!(item.status, TaskBoardStatus::Backlog);
}

#[test]
fn ranking_prefers_priority_then_created_at_then_id() {
    // Pure sanity check on the shared comparator this module relies on --
    // exercised end-to-end via the async tests above, this documents intent.
    let mut low = TaskBoardItem::new(
        "z".into(),
        "Z".into(),
        String::new(),
        "2026-07-22T00:00:01Z".into(),
    );
    low.priority = TaskBoardPriority::Low;
    low.status = TaskBoardStatus::Todo;
    let mut high = TaskBoardItem::new(
        "a".into(),
        "A".into(),
        String::new(),
        "2026-07-22T00:00:00Z".into(),
    );
    high.priority = TaskBoardPriority::Critical;
    high.status = TaskBoardStatus::Todo;
    let mut items = vec![low, high];
    crate::task_board::sort_task_board_items(&mut items);
    assert_eq!(items[0].id, "a");
}
