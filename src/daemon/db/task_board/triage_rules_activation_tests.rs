use sqlx::{query_as, query_scalar};
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, RUNTIME_RULES_EVALUATOR_IDENTITY, TaskBoardItem,
    TaskBoardPriority, TaskBoardStatus, TriagePriorityAction, TriageRule, TriageRuleCondition,
    TriageRuleOutcome, TriageRuleSetV1, TriageVerdict,
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

async fn item_status(db: &AsyncDaemonDb, item_id: &str) -> String {
    query_scalar("SELECT status FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read status")
}

async fn item_priority(db: &AsyncDaemonDb, item_id: &str) -> String {
    query_scalar("SELECT priority FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read priority")
}

async fn current_decision_evaluator(db: &AsyncDaemonDb, item_id: &str) -> (String, i64) {
    query_as::<_, (String, i64)>(
        "SELECT evaluator_identity, evaluator_version FROM task_board_triage_decisions
         WHERE item_id = ?1 AND is_current = 1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read current decision evaluator")
}

#[tokio::test]
async fn invalid_candidate_is_rejected_and_never_reaches_the_revision_table() {
    let (_directory, db) = connect().await;
    let mut invalid = bug_rule_set();
    invalid.schema_version = 99;
    let result = db
        .activate_task_board_triage_rules(Some(invalid), "owner".into(), None)
        .await
        .expect("activation call succeeds even when the candidate is rejected");
    assert!(!result.activated);
    assert!(!result.validation.is_valid());
    assert!(db
        .list_task_board_triage_rules_revisions(10)
        .await
        .expect("list revisions")
        .is_empty());
    let audit = db.list_task_board_triage_rules_audit(10).await.expect("list audit");
    assert_eq!(audit.len(), 1);
    assert_eq!(audit[0].kind, crate::task_board::TriageRuleSetAuditKind::ActivationRejected);

    // The rejection audit row is the only durable record a malformed
    // candidate ever existed, so its validation report must be persisted.
    let validation_json: Option<String> =
        query_scalar("SELECT validation_json FROM task_board_triage_rule_set_audit WHERE audit_id = ?1")
            .bind(&audit[0].audit_id)
            .fetch_one(db.pool())
            .await
            .expect("read persisted validation json");
    let validation_json = validation_json.expect("validation json persisted on rejection");
    assert!(validation_json.contains("unsupported_schema_version"));
}

#[tokio::test]
async fn activating_a_valid_candidate_reevaluates_eligible_items_and_records_the_evaluator() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    db.create_task_board_item(inbox_item("plain-item", Vec::new()))
        .await
        .expect("create item");

    let result = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    assert!(result.activated);
    assert_eq!(result.revision, Some(1));
    assert_eq!(result.reevaluated_item_count, 2);

    assert_eq!(item_status(&db, "bug-item").await, "todo");
    assert_eq!(item_priority(&db, "bug-item").await, "critical");
    assert_eq!(item_status(&db, "plain-item").await, "inbox");

    let (identity, version) = current_decision_evaluator(&db, "bug-item").await;
    assert_eq!(identity, RUNTIME_RULES_EVALUATOR_IDENTITY);
    assert_eq!(version, 1);

    let revisions = db.list_task_board_triage_rules_revisions(10).await.expect("list revisions");
    assert_eq!(revisions.len(), 1);
    assert_eq!(revisions[0].status, crate::task_board::TriageRuleSetRevisionStatus::Active);
}

#[tokio::test]
async fn stale_expected_active_revision_is_rejected_atomically() {
    let (_directory, db) = connect().await;
    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("first activation");

    let error = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect_err("stale expected revision must fail");
    assert!(format!("{error}").contains("revision changed"));

    let revisions = db.list_task_board_triage_rules_revisions(10).await.expect("list revisions");
    assert_eq!(revisions.len(), 1, "no second revision was written");
}

#[tokio::test]
async fn activating_a_second_revision_supersedes_the_first() {
    let (_directory, db) = connect().await;
    let first = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("first activation");
    let second = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), first.revision)
        .await
        .expect("second activation");
    assert_eq!(second.revision, Some(2));

    let revisions = db.list_task_board_triage_rules_revisions(10).await.expect("list revisions");
    assert_eq!(revisions.len(), 2);
    let active_count = revisions
        .iter()
        .filter(|revision| revision.status == crate::task_board::TriageRuleSetRevisionStatus::Active)
        .count();
    assert_eq!(active_count, 1);
}

#[tokio::test]
async fn deactivating_reverts_eligible_items_to_the_builtin_v1_default() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let activation = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    assert_eq!(item_priority(&db, "bug-item").await, "critical");

    let deactivation = db
        .activate_task_board_triage_rules(None, "owner".into(), activation.revision)
        .await
        .expect("deactivate");
    assert!(deactivation.activated);
    assert_eq!(deactivation.revision, None);

    let (identity, _version) = current_decision_evaluator(&db, "bug-item").await;
    assert_eq!(identity, BUILTIN_V1_EVALUATOR_IDENTITY);
    assert_eq!(item_status(&db, "bug-item").await, "todo", "BuiltInV1 also promotes a labeled item");
}

/// Regression proof for atomicity: an activation that fails after it has
/// already superseded the prior active revision and inserted the candidate
/// row (here, forced by a `u32` overflow while computing the new
/// evaluator's version) must roll the whole transaction back, leaving the
/// prior active revision untouched, no orphaned new revision row, no audit
/// row, and no new decisions.
#[tokio::test]
async fn activation_failing_after_supersede_and_insert_rolls_back_completely() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(inbox_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let first = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("first activation");
    assert_eq!(first.revision, Some(1));
    let decision_count_before: i64 =
        query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'bug-item'")
            .fetch_one(db.pool())
            .await
            .expect("count decisions before");

    let overflowing_revision = i64::from(u32::MAX) + 1;
    let rules_json = serde_json::to_string(&bug_rule_set()).expect("encode seeded rule set");
    sqlx::query(
        "INSERT INTO task_board_triage_rule_set_revisions (
             revision, schema_version, rules_json, status, actor, activated_at, superseded_at
         ) VALUES (?1, 1, ?2, 'superseded', 'seed', '2026-07-24T00:00:00Z', '2026-07-24T00:00:01Z')",
    )
    .bind(overflowing_revision)
    .bind(&rules_json)
    .execute(db.pool())
    .await
    .expect("seed overflowing revision row");
    let audit_count_before = db.list_task_board_triage_rules_audit(10).await.expect("list audit").len();

    let error = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), Some(1))
        .await
        .expect_err("u32 overflow while computing the new evaluator version must fail");
    assert!(format!("{error}").contains("out of range"));

    let revisions = db.list_task_board_triage_rules_revisions(10).await.expect("list revisions");
    assert_eq!(revisions.len(), 2, "no new revision row beyond the original two");
    let revision_one = revisions
        .iter()
        .find(|revision| revision.revision == 1)
        .expect("revision 1 present");
    assert_eq!(
        revision_one.status,
        crate::task_board::TriageRuleSetRevisionStatus::Active,
        "the supersede must have rolled back with the rest of the failed activation"
    );
    let audit_count_after = db.list_task_board_triage_rules_audit(10).await.expect("list audit").len();
    assert_eq!(
        audit_count_after, audit_count_before,
        "no audit row from a fully rolled-back activation"
    );
    let decision_count_after: i64 =
        query_scalar("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'bug-item'")
            .fetch_one(db.pool())
            .await
            .expect("count decisions after");
    assert_eq!(
        decision_count_after, decision_count_before,
        "no new decision from a fully rolled-back activation"
    );
}

/// Concurrent item creation and rule-set activation on the same daemon must
/// serialize through SQLite's immediate-transaction locking without a torn
/// or duplicated write: the item ends up with exactly one *current*
/// decision, made by whichever evaluator actually committed around it.
#[tokio::test]
async fn concurrent_item_creation_and_activation_serialize_without_anomaly() {
    let (_directory, db) = connect().await;

    let (create_result, activate_result) = tokio::join!(
        db.create_task_board_item_with_triage(inbox_item("concurrent-item", vec!["kind/bug".into()])),
        db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
    );

    create_result.expect("create item");
    let activation = activate_result.expect("activate rule set");
    assert!(activation.activated);

    let current_decision_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM task_board_triage_decisions
         WHERE item_id = 'concurrent-item' AND is_current = 1",
    )
    .fetch_one(db.pool())
    .await
    .expect("count current decisions");
    assert_eq!(
        current_decision_count, 1,
        "exactly one current decision, never zero or a torn write"
    );

    let (identity, _version) = current_decision_evaluator(&db, "concurrent-item").await;
    assert!(
        identity == BUILTIN_V1_EVALUATOR_IDENTITY || identity == RUNTIME_RULES_EVALUATOR_IDENTITY,
        "decided by whichever evaluator actually committed around it, unexpected: {identity}"
    );
    assert_eq!(item_status(&db, "concurrent-item").await, "todo");
}
