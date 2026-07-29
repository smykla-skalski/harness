use tempfile::tempdir;

use super::{current_triage_decision_in_tx, record_triage_decision_in_tx};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::types::TaskBoardItemKind;
use crate::task_board::{TaskBoardItem, TriageCause, TriageReasonCode, TriageVerdict};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

/// Umbrella kind keeps the seed ineligible if a triaging create path is used,
/// so these persistence-layer tests never collide with an automatic decision.
async fn seed_item(db: &AsyncDaemonDb, id: &str) {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-22T00:00:00Z".into(),
    );
    item.kind = TaskBoardItemKind::Umbrella;
    db.create_task_board_item(item).await.expect("seed item");
}

#[tokio::test]
async fn records_and_reads_the_current_decision() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;

    let mut transaction = db
        .begin_immediate_transaction("test record decision")
        .await
        .expect("begin transaction");
    assert!(
        current_triage_decision_in_tx(&mut transaction, "item-1")
            .await
            .expect("read before any decision")
            .is_none()
    );
    let decision = record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "task_board.triage.builtin_v1",
        1,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        TriageCause::Initial,
        "2026-07-22T00:00:00Z",
    )
    .await
    .expect("record decision");
    transaction.commit().await.expect("commit");
    assert_eq!(decision.verdict, TriageVerdict::Todo);

    let mut read_transaction = db
        .begin_immediate_transaction("test read decision")
        .await
        .expect("begin read transaction");
    let current = current_triage_decision_in_tx(&mut read_transaction, "item-1")
        .await
        .expect("read current decision")
        .expect("decision exists");
    assert_eq!(current, decision);
}

#[tokio::test]
async fn recording_again_supersedes_the_prior_generation_and_stays_current() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;

    let mut transaction = db
        .begin_immediate_transaction("test first decision")
        .await
        .expect("begin transaction");
    record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Undecided,
        TriageReasonCode::NoMeaningfulLabels,
        None,
        "task_board.triage.builtin_v1",
        1,
        "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        TriageCause::Initial,
        "2026-07-22T00:00:00Z",
    )
    .await
    .expect("record first decision");
    transaction.commit().await.expect("commit first");

    let mut transaction = db
        .begin_immediate_transaction("test second decision")
        .await
        .expect("begin transaction");
    let second = record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "task_board.triage.builtin_v1",
        1,
        "sha256:2222222222222222222222222222222222222222222222222222222222222222",
        TriageCause::FingerprintChanged,
        "2026-07-22T01:00:00Z",
    )
    .await
    .expect("record second decision");
    transaction.commit().await.expect("commit second");

    let count: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'item-1'")
            .fetch_one(db.pool())
            .await
            .expect("count decisions");
    assert_eq!(count.0, 2);

    let current_count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'item-1' AND is_current = 1",
    )
    .fetch_one(db.pool())
    .await
    .expect("count current decisions");
    assert_eq!(current_count.0, 1);

    let mut read_transaction = db
        .begin_immediate_transaction("test read after supersede")
        .await
        .expect("begin read transaction");
    let current = current_triage_decision_in_tx(&mut read_transaction, "item-1")
        .await
        .expect("read current decision")
        .expect("decision exists");
    assert_eq!(current, second);
}

#[tokio::test]
async fn rejects_non_canonical_evaluator_identity_version_and_fingerprint() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;

    let mut transaction = db
        .begin_immediate_transaction("test rejects malformed identity")
        .await
        .expect("begin transaction");
    let blank_identity = record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "",
        1,
        "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        TriageCause::Initial,
        "2026-07-22T00:00:00Z",
    )
    .await;
    assert!(blank_identity.is_err());

    let zero_version = record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "task_board.triage.builtin_v1",
        0,
        "sha256:3333333333333333333333333333333333333333333333333333333333333333",
        TriageCause::Initial,
        "2026-07-22T00:00:00Z",
    )
    .await;
    assert!(zero_version.is_err());

    let malformed_fingerprint = record_triage_decision_in_tx(
        &mut transaction,
        "item-1",
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "task_board.triage.builtin_v1",
        1,
        "not-a-fingerprint",
        TriageCause::Initial,
        "2026-07-22T00:00:00Z",
    )
    .await;
    assert!(malformed_fingerprint.is_err());
}
