use tempfile::tempdir;

use super::super::triage_apply::placement_matches_verdict;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    AGENT_V1_EVALUATOR_IDENTITY, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus,
    TaskBoardTriageEscalationConfig, TaskBoardTriageEscalationVerdictOutcome, TriageVerdict,
};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    (directory, db)
}

fn backlog_item_no_labels(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Vague title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item
}

async fn seed_running_escalation(db: &AsyncDaemonDb, item_id: &str) -> (String, String, String) {
    db.create_task_board_item_with_triage(backlog_item_no_labels(item_id))
        .await
        .expect("create item");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim escalation");
    let claimed = claimed.into_iter().next().expect("one claimed escalation");
    (
        claimed.escalation_id,
        claimed.verdict_token,
        claimed.evidence_fingerprint,
    )
}

async fn lane_producer(db: &AsyncDaemonDb, item_id: &str) -> Option<String> {
    let item = db.task_board_item(item_id).await.expect("load item");
    match item.lane_origin {
        Some(TaskBoardLaneOrigin::Automatic { producer }) => Some(producer),
        _ => None,
    }
}

async fn decision_generation_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("count decision generations")
}

#[tokio::test]
async fn a_valid_todo_verdict_lands_and_stamps_the_agent_producer() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            &token,
            &fingerprint,
            TriageVerdict::Todo,
            "clear enough once you read the body",
        )
        .await
        .expect("report verdict");

    assert_eq!(outcome, TaskBoardTriageEscalationVerdictOutcome::Accepted);
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    // C3: placement must be attributed to the agent evaluator, not BuiltInV1.
    assert_eq!(
        lane_producer(&db, "item-1").await.as_deref(),
        Some(AGENT_V1_EVALUATOR_IDENTITY)
    );
}

#[tokio::test]
async fn an_undecided_verdict_leaves_the_item_in_backlog() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            &token,
            &fingerprint,
            TriageVerdict::Undecided,
            "still nothing to go on",
        )
        .await
        .expect("report verdict");

    assert_eq!(outcome, TaskBoardTriageEscalationVerdictOutcome::Accepted);
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Backlog);
}

/// C3: `placement_matches_verdict`'s producer congruence check must
/// recognize what an agent verdict actually stamps -- if it didn't, the
/// retained-effect leg (see `triage_cause`'s `AGENT_V1` pin and its callers'
/// dynamic-producer fix) would see a permanent desync and keep re-applying
/// placement on every unchanged touch, exactly the desync #334's F1 fix
/// prevented for rules/BuiltInV1.
#[tokio::test]
async fn placement_matches_verdict_recognizes_the_agent_producer_as_congruent() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "clear enough",
    )
    .await
    .expect("report verdict");

    let item = db.task_board_item("item-1").await.expect("load item");
    assert!(
        placement_matches_verdict(&item, TriageVerdict::Todo, AGENT_V1_EVALUATOR_IDENTITY),
        "the agent-stamped placement must read back as congruent with its own producer"
    );
}

#[tokio::test]
async fn a_wrong_token_is_rejected_without_any_write() {
    let (_directory, db) = connect().await;
    let (escalation_id, _token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    let generations_before = decision_generation_count(&db, "item-1").await;

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            "not-the-real-token",
            &fingerprint,
            TriageVerdict::Todo,
            "attempted forgery",
        )
        .await
        .expect("report verdict");

    assert!(matches!(
        outcome,
        TaskBoardTriageEscalationVerdictOutcome::Rejected(_)
    ));
    assert_eq!(
        decision_generation_count(&db, "item-1").await,
        generations_before,
        "a wrong token must never write a decision"
    );
    let status: String = sqlx::query_scalar(
        "SELECT status FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&escalation_id)
    .fetch_one(db.pool())
    .await
    .expect("escalation status unchanged");
    assert_eq!(status, "running", "a wrong token must not even mark the row rejected");
}

#[tokio::test]
async fn an_already_terminal_escalation_is_rejected() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;
    db.report_task_board_triage_escalation_verdict(
        &escalation_id,
        &token,
        &fingerprint,
        TriageVerdict::Todo,
        "first report",
    )
    .await
    .expect("first report");

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            &token,
            &fingerprint,
            TriageVerdict::Undecided,
            "second report should be refused",
        )
        .await
        .expect("second report call");

    assert!(matches!(
        outcome,
        TaskBoardTriageEscalationVerdictOutcome::Rejected(_)
    ));
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Todo, "the first verdict still stands");
}

#[tokio::test]
async fn stale_evidence_is_rejected_and_reenqueues_for_the_current_fingerprint() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, stale_fingerprint) = seed_running_escalation(&db, "item-1").await;

    db.update_task_board_item_with_triage("item-1", |item| {
        item.title = "A completely different vague title".into();
        Ok(true)
    })
    .await
    .expect("change evidence while escalation is running");

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            &token,
            &stale_fingerprint,
            TriageVerdict::Todo,
            "based on evidence that no longer applies",
        )
        .await
        .expect("report verdict");

    assert!(matches!(
        outcome,
        TaskBoardTriageEscalationVerdictOutcome::Rejected(_)
    ));
    let item = db.task_board_item("item-1").await.expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Backlog, "stale verdict never lands");
    let fresh_pending: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_triage_escalations
         WHERE item_id = 'item-1' AND status = 'pending'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count pending escalations");
    assert_eq!(fresh_pending, 1, "a fresh escalation was enqueued for the new evidence");
}

#[tokio::test]
async fn an_override_set_while_running_causes_rejection() {
    let (_directory, db) = connect().await;
    let (escalation_id, token, fingerprint) = seed_running_escalation(&db, "item-1").await;

    db.set_task_board_triage_override(crate::daemon::db::task_board::TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "human".into(),
        reason: None,
        expected_item_revision: 1,
        expected_items_change_seq: 1,
    })
    .await
    .expect("set override while escalation running");

    let outcome = db
        .report_task_board_triage_escalation_verdict(
            &escalation_id,
            &token,
            &fingerprint,
            TriageVerdict::Undecided,
            "should be refused, a human already decided",
        )
        .await
        .expect("report verdict");

    assert!(matches!(
        outcome,
        TaskBoardTriageEscalationVerdictOutcome::Rejected(_)
    ));
}

#[path = "triage_apply_agent_lifecycle_tests.rs"]
mod lifecycle_tests;
