use tempfile::tempdir;

use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, TaskBoardItem, TaskBoardStatus,
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

#[tokio::test]
async fn loads_every_live_inbox_and_todo_item_with_its_decision_and_override() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("item-a", vec!["kind/bug".into()]))
        .await
        .expect("create item-a");
    db.create_task_board_item(inbox_item("item-b", Vec::new()))
        .await
        .expect("create item-b");

    let mut transaction = db
        .begin_immediate_transaction("test bulk load")
        .await
        .expect("begin");
    let entries = load_triage_bulk_entries_in_tx(&mut transaction).await.expect("load entries");
    transaction.commit().await.expect("commit");

    assert_eq!(entries.len(), 2);
    let item_a = entries
        .iter()
        .find(|entry| entry.item.id == "item-a")
        .expect("item-a present");
    // item-a was created but never triaged in this test, so it carries no
    // decision yet and no override.
    assert!(item_a.current_decision.is_none());
    assert!(item_a.override_.is_none());
    assert!(item_a.revision > 0);
}

#[tokio::test]
async fn excludes_deleted_and_non_inbox_todo_items() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("kept", Vec::new()))
        .await
        .expect("create kept");
    let mut done = inbox_item("done", Vec::new());
    done.status = TaskBoardStatus::Done;
    db.create_task_board_item(done).await.expect("create done");

    let mut transaction = db
        .begin_immediate_transaction("test bulk load exclusion")
        .await
        .expect("begin");
    let entries = load_triage_bulk_entries_in_tx(&mut transaction).await.expect("load entries");
    transaction.commit().await.expect("commit");

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].item.id, "kept");
}

#[tokio::test]
async fn reports_the_current_decision_verdict_when_one_exists() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(inbox_item("triaged", vec!["kind/bug".into()]))
        .await
        .expect("create item");
    let mut transaction = db
        .begin_immediate_transaction("test seed decision")
        .await
        .expect("begin");
    let (mut item, revision) = super::super::items::load_item_in_tx(&mut transaction, "triaged")
        .await
        .expect("load item")
        .expect("item exists");
    super::super::triage_apply::apply_builtin_v1_triage_in_tx(
        &mut transaction,
        &mut item,
        "2026-07-24T00:00:00Z",
        false,
        None,
    )
    .await
    .expect("apply triage")
    .expect("decision recorded");
    super::super::items::replace_item_in_tx(&mut transaction, &item, revision + 1)
        .await
        .expect("persist");
    transaction.commit().await.expect("commit seed");

    let mut transaction = db
        .begin_immediate_transaction("test bulk load with decision")
        .await
        .expect("begin");
    let entries = load_triage_bulk_entries_in_tx(&mut transaction).await.expect("load entries");
    transaction.commit().await.expect("commit");

    let entry = entries
        .iter()
        .find(|entry| entry.item.id == "triaged")
        .expect("item present");
    let decision = entry.current_decision.as_ref().expect("decision present");
    assert_eq!(decision.verdict, TriageVerdict::Todo);
    assert_eq!(decision.evaluator_identity, BUILTIN_V1_EVALUATOR_IDENTITY);
    assert_eq!(decision.evaluator_version, BUILTIN_V1_EVALUATOR_VERSION);
    assert!(!decision.evidence_fingerprint.is_empty());
}
