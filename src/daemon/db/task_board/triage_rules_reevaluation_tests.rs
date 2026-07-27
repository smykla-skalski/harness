use sqlx::query_scalar;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    OVERRIDE_PLACEMENT_PRODUCER, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TriagePriorityAction, TriageRule, TriageRuleCondition, TriageRuleOutcome, TriageRuleSetV1,
    TriageVerdict,
};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn inbox_item(id: &str, tags: Vec<String>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Inbox;
    item.tags = tags;
    item
}

fn bug_rule_set() -> TriageRuleSetV1 {
    TriageRuleSetV1 {
        schema_version: crate::task_board::TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![TriageRule {
            id: "bug".into(),
            when: vec![TriageRuleCondition::LabelsHasAny { labels: vec!["kind/bug".into()] }],
            outcome: TriageRuleOutcome {
                verdict: TriageVerdict::Todo,
                priority_action: TriagePriorityAction::SetTo { priority: TaskBoardPriority::Critical },
            },
        }],
        default_outcome: TriageRuleOutcome {
            verdict: TriageVerdict::Undecided,
            priority_action: TriagePriorityAction::Keep,
        },
    }
}

async fn seed_active_dispatch_reservation(db: &AsyncDaemonDb, item_id: &str) {
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, claim_token, claimed_at,
             created_at, updated_at
         ) VALUES ('intent-1', ?1, 'session-1', 'work-1', 'workflow-1', '{}',
                   'held', 0, '2026-07-24T00:00:00Z', NULL, NULL,
                   '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z')",
    )
    .bind(item_id)
    .execute(db.pool())
    .await
    .expect("seed dispatch reservation");
}

async fn item_status(db: &AsyncDaemonDb, item_id: &str) -> String {
    query_scalar("SELECT status FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read status")
}

async fn decision_generation_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("count decision generations")
}

#[tokio::test]
async fn an_item_with_an_active_dispatch_reservation_is_skipped_entirely() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("reserved", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    seed_active_dispatch_reservation(&db, "reserved").await;

    let result = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    assert_eq!(result.reevaluated_item_count, 0);
    assert_eq!(item_status(&db, "reserved").await, "inbox", "reserved item is untouched");
}

/// Regression test: `activate(candidate=None, expected=None)` when nothing
/// is already active used to pass CAS and unconditionally record a fresh
/// `ActiveEvaluatorChanged` decision generation per eligible item, even
/// though `BuiltInV1` was already the recorded evaluator with the same
/// evidence fingerprint -- spamming decision history on every repeated
/// no-op deactivation.
#[tokio::test]
async fn deactivating_when_nothing_is_active_records_zero_decisions() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(inbox_item("plain", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let count_before = decision_generation_count(&db, "plain").await;
    assert_eq!(count_before, 1, "creation records exactly one BuiltInV1 decision");

    let result = db
        .activate_task_board_triage_rules(None, "owner".into(), None)
        .await
        .expect("deactivate when nothing active");

    assert!(result.activated);
    assert_eq!(result.reevaluated_item_count, 1);
    assert_eq!(
        decision_generation_count(&db, "plain").await,
        count_before,
        "a no-op deactivation must not append a decision generation"
    );
}

#[tokio::test]
async fn a_second_consecutive_deactivation_is_a_decision_noop() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(inbox_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");

    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    let first_deactivation = db
        .activate_task_board_triage_rules(None, "owner".into(), Some(1))
        .await
        .expect("first deactivate");
    assert!(first_deactivation.activated);
    let count_after_first_deactivation = decision_generation_count(&db, "bug-item").await;

    let second_deactivation = db
        .activate_task_board_triage_rules(None, "owner".into(), None)
        .await
        .expect("second deactivate");

    assert!(second_deactivation.activated);
    assert_eq!(
        decision_generation_count(&db, "bug-item").await,
        count_after_first_deactivation,
        "a second consecutive deactivation must not append another decision generation"
    );
}

#[tokio::test]
async fn an_item_under_an_active_override_keeps_its_override_placement_but_gets_a_fresh_decision() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("overridden", Vec::new()))
        .await
        .expect("create item");
    db.set_task_board_triage_override(crate::daemon::db::task_board::TaskBoardTriageOverrideSetInput {
        item_id: "overridden".into(),
        verdict: TriageVerdict::Todo,
        actor: "human".into(),
        reason: None,
        expected_item_revision: 1,
        expected_items_change_seq: 1,
    })
    .await
    .expect("set override");

    let result = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    assert!(result.activated);

    // The override still wins placement (Todo), even though the new rule
    // set's default outcome for an unlabeled item is Undecided/Inbox.
    assert_eq!(item_status(&db, "overridden").await, "todo");
    let producer: String = query_scalar("SELECT lane_producer FROM task_board_items WHERE item_id = ?1")
        .bind("overridden")
        .fetch_one(db.pool())
        .await
        .expect("read lane origin producer");
    assert_eq!(producer, OVERRIDE_PLACEMENT_PRODUCER);
}
