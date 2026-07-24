use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardTriageEffectiveSource,
    TriagePriorityAction, TriageRule, TriageRuleCondition, TriageRuleOutcome, TriageRuleSetV1,
    TriageVerdict,
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

/// Regression test: preview used to include a reservation-held item in its
/// diff even though an actual activation's bulk reevaluation would skip it
/// entirely, so preview could promise a placement change that activation
/// would never apply.
#[tokio::test]
async fn preview_excludes_items_under_an_active_dispatch_reservation() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("reserved", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    seed_active_dispatch_reservation(&db, "reserved").await;

    let result = db
        .preview_task_board_triage_rules(bug_rule_set())
        .await
        .expect("preview");

    assert!(
        result.diff.iter().all(|entry| entry.item_id != "reserved"),
        "a reservation-held item must not appear in the preview diff"
    );
}

#[tokio::test]
async fn preview_never_writes_anything() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");

    let result = db
        .preview_task_board_triage_rules(bug_rule_set())
        .await
        .expect("preview");
    assert!(result.validation.is_valid());
    assert_eq!(result.diff.len(), 1);
    assert_eq!(result.diff[0].item_id, "bug-item");
    assert_eq!(result.diff[0].candidate_verdict, TriageVerdict::Todo);
    assert_eq!(result.diff[0].candidate_matched_rule_id, Some("bug".to_string()));
    assert!(result.diff[0].live_effective_verdict.is_none(), "item was never triaged before preview");
    assert!(result.diff[0].governs_placement_change);

    // No revisions, no decisions, no item mutation -- purely a read.
    assert!(db
        .list_task_board_triage_rules_revisions(10)
        .await
        .expect("list revisions")
        .is_empty());
    let status: String = sqlx::query_scalar("SELECT status FROM task_board_items WHERE item_id = 'bug-item'")
        .fetch_one(db.pool())
        .await
        .expect("read status");
    assert_eq!(status, "backlog");
}

#[tokio::test]
async fn invalid_candidate_preview_reports_no_diff() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("bug-item", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let mut invalid = bug_rule_set();
    invalid.schema_version = 99;

    let result = db.preview_task_board_triage_rules(invalid).await.expect("preview");
    assert!(!result.validation.is_valid());
    assert!(result.diff.is_empty());
}

#[tokio::test]
async fn an_active_override_never_reports_a_governing_placement_change() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(backlog_item("overridden", Vec::new()))
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
        .preview_task_board_triage_rules(bug_rule_set())
        .await
        .expect("preview");
    let entry = result
        .diff
        .iter()
        .find(|entry| entry.item_id == "overridden")
        .expect("entry present");
    assert_eq!(entry.live_effective_verdict, Some(TriageVerdict::Todo));
    assert_eq!(entry.live_effective_source, Some(TaskBoardTriageEffectiveSource::Override));
    assert_eq!(entry.candidate_verdict, TriageVerdict::Undecided);
    assert!(!entry.governs_placement_change, "override still wins regardless of the candidate");
}
