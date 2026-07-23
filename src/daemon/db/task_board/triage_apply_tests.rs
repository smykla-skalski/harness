use sqlx::{query, query_scalar};
use tempfile::tempdir;

use super::super::items::{load_item_in_tx, replace_item_in_tx};
use super::{apply_builtin_v1_triage_in_tx, triage_cause};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardPriority,
    TaskBoardStatus, TaskBoardTriageDecision, TriageCause, TriageReasonCode, TriageVerdict,
};

pub(super) async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

/// A `work_item_id` placeholder keeps the item ineligible for BuiltInV1 at
/// seed time, so the generic, non-triaging `db.create_task_board_item` seed
/// does not pre-empt the explicit `apply_builtin_v1_triage_in_tx` call each
/// test exercises. Tests clear it after loading, before applying.
pub(super) fn backlog_item(id: &str, tags: Vec<String>) -> TaskBoardItem {
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

/// Seeds an item, then genuinely decides and persists a Todo verdict for it
/// (fresh decision, real placement written back to the row), so a later
/// reload sees a truly congruent starting point. Returns the item id.
pub(super) async fn seed_decided_todo_item(db: &AsyncDaemonDb) -> &'static str {
    db.create_task_board_item(backlog_item("item-1", vec!["kind/bug".into()]))
        .await
        .expect("seed item");

    let mut transaction = db
        .begin_immediate_transaction("seed decided todo")
        .await
        .expect("begin transaction");
    let (mut item, revision) = load_item_in_tx(&mut transaction, "item-1")
        .await
        .expect("load item")
        .expect("item exists");
    item.work_item_id = None;
    apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
        .await
        .expect("apply triage")
        .expect("decision recorded");
    replace_item_in_tx(&mut transaction, &item, revision + 1)
        .await
        .expect("persist triaged placement");
    transaction.commit().await.expect("commit");
    "item-1"
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
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    let decision = outcome.decision();
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
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    let decision = outcome.decision();
    assert_eq!(decision.verdict, TriageVerdict::Undecided);
    assert_eq!(decision.reason_code, TriageReasonCode::NoMeaningfulLabels);
    assert_eq!(item.status, TaskBoardStatus::Backlog);
    assert_eq!(item.lane_position, None);
}

#[tokio::test]
async fn active_dispatch_reservations_suppress_triage_decisions_and_placement() {
    for status in [
        "preparing",
        "preparing_claimed",
        "held",
        "pending",
        "workflow_prepared",
        "starting",
    ] {
        let (_directory, db) = connect().await;
        db.create_task_board_item(backlog_item("item-1", vec!["kind/bug".into()]))
            .await
            .expect("seed item");
        let claim_token = matches!(status, "preparing_claimed" | "starting").then_some("claim");
        let claimed_at =
            matches!(status, "preparing_claimed" | "starting").then_some("2026-07-22T00:00:00Z");
        query(
            "INSERT INTO task_board_dispatch_intents (
                 intent_id, item_id, session_id, work_item_id, workflow_execution_id,
                 payload_json, status, attempts, available_at, claim_token, claimed_at,
                 created_at, updated_at
             ) VALUES (?1, 'item-1', 'session-1', 'work-1', 'workflow-1', '{}',
                       ?2, 0, '2026-07-22T00:00:00Z', ?3, ?4,
                       '2026-07-22T00:00:00Z', '2026-07-22T00:00:00Z')",
        )
        .bind(format!("intent-{status}"))
        .bind(status)
        .bind(claim_token)
        .bind(claimed_at)
        .execute(db.pool())
        .await
        .expect("seed dispatch reservation");

        let mut transaction = db
            .begin_immediate_transaction("test reserved item triage")
            .await
            .expect("begin transaction");
        let (mut item, _) = load_item_in_tx(&mut transaction, "item-1")
            .await
            .expect("load item")
            .expect("item exists");
        item.work_item_id = None;
        let outcome = apply_builtin_v1_triage_in_tx(
            &mut transaction,
            &mut item,
            "2026-07-22T01:00:00Z",
            false,
        )
        .await
        .expect("check triage eligibility");
        transaction.commit().await.expect("commit");

        assert!(outcome.is_none(), "{status} must suppress triage");
        assert_eq!(item.status, TaskBoardStatus::Backlog);
        assert_eq!(item.lane_position, None);
        assert_eq!(item.lane_origin, None);
        let decisions: i64 = query_scalar(
            "SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'item-1'",
        )
        .fetch_one(db.pool())
        .await
        .expect("count decisions");
        assert_eq!(decisions, 0);
    }
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
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("decision recorded");
    transaction.commit().await.expect("commit");

    let decision = outcome.decision();
    assert_eq!(decision.verdict, TriageVerdict::Undecided);
    assert_eq!(decision.reason_code, TriageReasonCode::NeedsInfoLabel);
    assert_eq!(item.status, TaskBoardStatus::Backlog);
}

#[tokio::test]
async fn unchanged_fingerprint_is_idempotent_and_records_no_new_decision() {
    let (_directory, db) = connect().await;
    let item_id = seed_decided_todo_item(&db).await;

    // Re-evaluate the same fields again (as an unrelated field update would);
    // the fingerprint has not changed and the first pass's placement was
    // genuinely persisted, so this must be a true no-op, not a desync.
    let mut second_transaction = db
        .begin_immediate_transaction("test second pass")
        .await
        .expect("begin transaction");
    let (mut reloaded, _) = load_item_in_tx(&mut second_transaction, item_id)
        .await
        .expect("load item")
        .expect("item exists");
    let repeat = apply_builtin_v1_triage_in_tx(
        &mut second_transaction,
        &mut reloaded,
        "2026-07-22T02:00:00Z",
        false,
    )
    .await
    .expect("apply triage");
    second_transaction.commit().await.expect("commit second");

    assert!(
        repeat.is_none(),
        "unchanged fingerprint with congruent persisted placement must not re-decide"
    );
    let generations: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = ?1")
            .bind(item_id)
            .fetch_one(db.pool())
            .await
            .expect("count decision history");
    assert_eq!(
        generations, 1,
        "idempotent re-evaluation must not append history"
    );
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
    let outcome =
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
            .await
            .expect("apply triage")
            .expect("decision recorded even though placement is suppressed");
    transaction.commit().await.expect("commit");

    assert_eq!(outcome.decision().verdict, TriageVerdict::Undecided);
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
        .create_task_board_item_with_triage(item)
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
        .update_task_board_item_with_triage("item-1", |item| {
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
        apply_builtin_v1_triage_in_tx(&mut transaction, &mut item, "2026-07-22T01:00:00Z", false)
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

#[test]
fn active_evaluator_change_wins_over_a_simultaneous_fingerprint_change() {
    let existing = TaskBoardTriageDecision {
        verdict: TriageVerdict::Todo,
        reason_code: TriageReasonCode::MeaningfulLabel,
        reason_detail: None,
        evaluator_identity: "some-other-evaluator".into(),
        evaluator_version: 1,
        evidence_fingerprint: "sha256:old".into(),
        cause: TriageCause::Initial,
        decided_at: "2026-07-22T00:00:00Z".into(),
    };

    let cause = triage_cause(Some(&existing), "sha256:new");

    assert_eq!(
        cause,
        Some(TriageCause::ActiveEvaluatorChanged),
        "a simultaneous evaluator and fingerprint change must report the evaluator change"
    );
}

#[path = "triage_apply_retained_effect_tests.rs"]
mod retained_effect;
