use sqlx::query_scalar;
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

fn backlog_item(id: &str, tags: Vec<String>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
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

async fn decision_evaluator(db: &AsyncDaemonDb, item_id: &str) -> (String, i64) {
    let identity: String = query_scalar(
        "SELECT evaluator_identity FROM task_board_triage_decisions WHERE item_id = ?1 AND is_current = 1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read decision evaluator identity");
    let version: i64 = query_scalar(
        "SELECT evaluator_version FROM task_board_triage_decisions WHERE item_id = ?1 AND is_current = 1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read decision evaluator version");
    (identity, version)
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

async fn lane_producer(db: &AsyncDaemonDb, item_id: &str) -> Option<String> {
    query_scalar("SELECT lane_producer FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read lane producer")
}

async fn lane_set_at(db: &AsyncDaemonDb, item_id: &str) -> Option<String> {
    query_scalar("SELECT lane_set_at FROM task_board_items WHERE item_id = ?1")
        .bind(item_id)
        .fetch_one(db.pool())
        .await
        .expect("read lane set at")
}

async fn lane_position_changed_audit_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM audit_events WHERE kind = 'task_board.item.lane_position_changed' AND subject = ?1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count lane position audit events")
}

async fn items_change_seq(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT change_seq FROM change_tracking WHERE scope = 'task_board:items'")
        .fetch_one(db.pool())
        .await
        .expect("read items change seq")
}

#[tokio::test]
async fn without_an_active_rule_set_item_creation_still_uses_builtin_v1() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item("plain", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let (identity, _version) = decision_evaluator(&db, "plain").await;
    assert_eq!(identity, BUILTIN_V1_EVALUATOR_IDENTITY);
    assert_eq!(item_status(&db, "plain").await, "todo");
}

#[tokio::test]
async fn with_an_active_rule_set_item_creation_uses_it_including_priority_action() {
    let (_directory, db) = connect().await;
    let activation = db
        .activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    assert_eq!(activation.revision, Some(1));

    db.create_task_board_item_with_triage(backlog_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");

    let (identity, version) = decision_evaluator(&db, "bug-item").await;
    assert_eq!(identity, RUNTIME_RULES_EVALUATOR_IDENTITY);
    assert_eq!(version, 1);
    assert_eq!(item_status(&db, "bug-item").await, "todo");
    assert_eq!(item_priority(&db, "bug-item").await, "critical");
}

#[tokio::test]
async fn an_item_created_under_an_active_rule_set_default_outcome_stays_in_backlog() {
    let (_directory, db) = connect().await;
    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");

    db.create_task_board_item_with_triage(backlog_item("plain-item", Vec::new()))
        .await
        .expect("create item");

    assert_eq!(item_status(&db, "plain-item").await, "backlog");
    let (identity, _version) = decision_evaluator(&db, "plain-item").await;
    assert_eq!(identity, RUNTIME_RULES_EVALUATOR_IDENTITY);
}

#[tokio::test]
async fn a_rules_promoted_item_is_stamped_with_the_rules_evaluator_as_lane_producer() {
    let (_directory, db) = connect().await;
    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");

    db.create_task_board_item_with_triage(backlog_item("bug-producer", vec!["kind/bug".into()]))
        .await
        .expect("create item");

    assert_eq!(
        lane_producer(&db, "bug-producer").await.as_deref(),
        Some(RUNTIME_RULES_EVALUATOR_IDENTITY)
    );
}

/// Regression test for a producer mismatch: `apply_placement_effect_in_tx`
/// used to always stamp `BUILTIN_V1_EVALUATOR_IDENTITY` regardless of which
/// evaluator actually decided, so a rules-placed item's `lane_producer`
/// never matched what `placement_matches_verdict` expected on a later
/// unchanged touch, causing every such touch to detect a false desync and
/// re-apply placement forever (churning `lane_set_at` and appending a
/// spurious lane-transition audit event on every touch).
#[tokio::test]
async fn a_second_unchanged_touch_of_a_rules_promoted_item_causes_no_placement_churn() {
    let (_directory, db) = connect().await;
    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");
    db.create_task_board_item_with_triage(backlog_item("bug-stable", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    assert_eq!(item_status(&db, "bug-stable").await, "todo");
    let lane_set_at_after_create = lane_set_at(&db, "bug-stable").await;
    let audit_count_after_create = lane_position_changed_audit_count(&db, "bug-stable").await;
    let seq_after_create = items_change_seq(&db).await;

    // Edits the body only -- unrelated to the rule set's evidence fingerprint
    // (labels/priority), so the fingerprint is unchanged and evaluation
    // takes the cause=None "reconcile placement" path this regression covers.
    db.update_task_board_item_with_triage("bug-stable", |item| {
        item.body = "unrelated edit".into();
        Ok(true)
    })
    .await
    .expect("update item body");

    assert_eq!(item_status(&db, "bug-stable").await, "todo");
    assert_eq!(
        lane_producer(&db, "bug-stable").await.as_deref(),
        Some(RUNTIME_RULES_EVALUATOR_IDENTITY)
    );
    assert_eq!(
        lane_set_at(&db, "bug-stable").await,
        lane_set_at_after_create,
        "an unrelated edit must not churn the placement's lane_set_at"
    );
    assert_eq!(
        lane_position_changed_audit_count(&db, "bug-stable").await,
        audit_count_after_create,
        "an unrelated edit must not append a spurious lane-transition audit event"
    );
    assert_eq!(
        items_change_seq(&db).await,
        seq_after_create + 1,
        "the body edit bumps the change sequence exactly once, not an extra time for triage churn"
    );
}

#[tokio::test]
async fn an_active_override_still_wins_placement_over_an_active_rule_set_on_update() {
    let (_directory, db) = connect().await;
    db.create_task_board_item_with_triage(backlog_item("overridden", Vec::new()))
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

    db.activate_task_board_triage_rules(Some(bug_rule_set()), "owner".into(), None)
        .await
        .expect("activate");

    // Activation's own bulk reevaluation already reasserted the override,
    // so the item is still Todo even though the rule set's default outcome
    // for an unlabeled item is Undecided.
    assert_eq!(item_status(&db, "overridden").await, "todo");
}
