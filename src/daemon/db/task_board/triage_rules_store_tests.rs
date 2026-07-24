use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TriageRuleSetV1, TriageVerdict};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn empty_candidate() -> TriageRuleSetV1 {
    TriageRuleSetV1 {
        schema_version: crate::task_board::TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: Vec::new(),
        default_outcome: crate::task_board::TriageRuleOutcome {
            verdict: TriageVerdict::Undecided,
            priority_action: crate::task_board::TriagePriorityAction::Keep,
        },
    }
}

#[tokio::test]
async fn no_draft_exists_before_any_save() {
    let (_directory, db) = connect().await;
    assert!(db.load_task_board_triage_rules_draft().await.expect("load draft").is_none());
}

#[tokio::test]
async fn saving_a_valid_candidate_persists_it_and_round_trips() {
    let (_directory, db) = connect().await;
    let result = db
        .save_task_board_triage_rules_draft(empty_candidate(), "author-1".into(), None)
        .await
        .expect("save draft");
    assert!(result.persisted);
    assert!(result.validation.is_valid());
    assert_eq!(result.revision, Some(1));

    let draft = db
        .load_task_board_triage_rules_draft()
        .await
        .expect("load draft")
        .expect("draft present");
    assert_eq!(draft.revision, 1);
    assert_eq!(draft.actor, "author-1");
    assert_eq!(draft.rules, empty_candidate());
}

#[tokio::test]
async fn stale_expected_revision_is_rejected_without_overwriting_the_draft() {
    let (_directory, db) = connect().await;
    db.save_task_board_triage_rules_draft(empty_candidate(), "author-1".into(), None)
        .await
        .expect("first save");

    let error = db
        .save_task_board_triage_rules_draft(empty_candidate(), "author-2".into(), None)
        .await
        .expect_err("stale expected revision must fail");
    assert!(format!("{error}").contains("revision changed"));

    let draft = db
        .load_task_board_triage_rules_draft()
        .await
        .expect("load draft")
        .expect("draft present");
    assert_eq!(draft.actor, "author-1");
}

#[tokio::test]
async fn an_invalid_candidate_is_never_persisted() {
    let (_directory, db) = connect().await;
    let mut invalid = empty_candidate();
    invalid.schema_version = 99;
    let result = db
        .save_task_board_triage_rules_draft(invalid, "author-1".into(), None)
        .await
        .expect("save draft call succeeds even when the candidate is rejected");
    assert!(!result.persisted);
    assert!(!result.validation.is_valid());
    assert!(db.load_task_board_triage_rules_draft().await.expect("load draft").is_none());
}

#[tokio::test]
async fn revisions_and_audit_lists_are_empty_before_any_activation() {
    let (_directory, db) = connect().await;
    assert!(db
        .list_task_board_triage_rules_revisions(10)
        .await
        .expect("list revisions")
        .is_empty());
    assert!(db
        .list_task_board_triage_rules_audit(10)
        .await
        .expect("list audit")
        .is_empty());
}
