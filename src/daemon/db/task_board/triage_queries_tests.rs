use tempfile::tempdir;

use super::super::triage_decisions::record_triage_decision_in_tx;
use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::types::TaskBoardItemKind;
use crate::task_board::{TaskBoardItem, TriageCause, TriageReasonCode, TriageVerdict};

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

async fn seed_item(db: &AsyncDaemonDb, item_id: &str) {
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.kind = TaskBoardItemKind::Umbrella;
    db.create_task_board_item(item).await.expect("seed item");
}

async fn record_decision(
    db: &AsyncDaemonDb,
    item_id: &str,
    fingerprint_digit: char,
    cause: TriageCause,
    decided_at: &str,
) {
    let fingerprint = format!("sha256:{}", fingerprint_digit.to_string().repeat(64));
    let mut transaction = db
        .begin_immediate_transaction("test record triage history")
        .await
        .expect("begin transaction");
    record_triage_decision_in_tx(
        &mut transaction,
        item_id,
        TriageVerdict::Todo,
        TriageReasonCode::MeaningfulLabel,
        None,
        "task_board.triage.builtin_v1",
        1,
        &fingerprint,
        cause,
        decided_at,
    )
    .await
    .expect("record decision");
    transaction.commit().await.expect("commit decision");
}

#[tokio::test]
async fn current_requires_an_existing_item_and_returns_optional_record() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;

    assert!(
        db.task_board_triage_current("item-1")
            .await
            .expect("read empty current")
            .is_none()
    );
    record_decision(
        &db,
        "item-1",
        '1',
        TriageCause::Initial,
        "2026-07-23T01:00:00Z",
    )
    .await;

    let current = db
        .task_board_triage_current("item-1")
        .await
        .expect("read current")
        .expect("current decision");
    assert_eq!(current.item_id, "item-1");
    assert_eq!(current.generation, 1);
    assert_eq!(current.verdict, TriageVerdict::Todo);
    assert_eq!(
        current.evidence_fingerprint.as_deref(),
        Some("sha256:1111111111111111111111111111111111111111111111111111111111111111")
    );
    assert!(current.superseded_at.is_none());

    assert!(db.task_board_triage_current("missing").await.is_err());
    assert!(db.task_board_triage_current("../unsafe").await.is_err());
}

#[tokio::test]
async fn history_is_bounded_descending_and_keyset_stable() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;
    for (digit, cause, decided_at) in [
        ('1', TriageCause::Initial, "2026-07-23T01:00:00Z"),
        ('2', TriageCause::FingerprintChanged, "2026-07-23T02:00:00Z"),
        ('3', TriageCause::FingerprintChanged, "2026-07-23T03:00:00Z"),
        (
            '4',
            TriageCause::ActiveEvaluatorChanged,
            "2026-07-23T04:00:00Z",
        ),
    ] {
        record_decision(&db, "item-1", digit, cause, decided_at).await;
    }

    let first = db
        .task_board_triage_history("item-1", None, 2)
        .await
        .expect("first page");
    assert_eq!(
        first
            .decisions
            .iter()
            .map(|decision| decision.generation)
            .collect::<Vec<_>>(),
        vec![4, 3]
    );
    assert_eq!(first.next_before_generation, Some(3));
    assert!(first.decisions[0].superseded_at.is_none());
    assert_eq!(
        first.decisions[1].superseded_at.as_deref(),
        Some("2026-07-23T04:00:00Z")
    );

    let second = db
        .task_board_triage_history("item-1", first.next_before_generation, 2)
        .await
        .expect("second page");
    assert_eq!(
        second
            .decisions
            .iter()
            .map(|decision| decision.generation)
            .collect::<Vec<_>>(),
        vec![2, 1]
    );
    assert_eq!(second.next_before_generation, None);

    let end = db
        .task_board_triage_history("item-1", Some(1), 2)
        .await
        .expect("end page");
    assert!(end.decisions.is_empty());
    assert_eq!(end.next_before_generation, None);
}

#[tokio::test]
async fn history_rejects_invalid_cursors_and_corrupt_rows() {
    let (_directory, db) = connect().await;
    seed_item(&db, "item-1").await;
    record_decision(
        &db,
        "item-1",
        '1',
        TriageCause::Initial,
        "2026-07-23T01:00:00Z",
    )
    .await;

    assert!(
        db.task_board_triage_history("item-1", Some(0), 10)
            .await
            .is_err()
    );
    assert!(
        db.task_board_triage_history("item-1", Some(u64::MAX), 10)
            .await
            .is_err()
    );
    assert!(
        db.task_board_triage_history("item-1", None, 0)
            .await
            .is_err()
    );
    assert!(
        db.task_board_triage_history("item-1", None, TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT + 1,)
            .await
            .is_err()
    );

    sqlx::query(
        "UPDATE task_board_triage_decisions
         SET evaluator_version = ?1
         WHERE item_id = 'item-1'",
    )
    .bind(i64::from(u32::MAX) + 1)
    .execute(db.pool())
    .await
    .expect("corrupt evaluator version beyond public range");
    assert!(db.task_board_triage_current("item-1").await.is_err());

    sqlx::query(
        "UPDATE task_board_triage_decisions
         SET evaluator_version = 1,
             evidence_fingerprint = ?1
         WHERE item_id = 'item-1'",
    )
    .bind(format!("sha256:{}", "g".repeat(64)))
    .execute(db.pool())
    .await
    .expect("corrupt fingerprint within SQL shape");
    assert!(db.task_board_triage_current("item-1").await.is_err());

    sqlx::query(
        "UPDATE task_board_triage_decisions
         SET decision_id = 'not-canonical',
             evidence_fingerprint = ?1
         WHERE item_id = 'item-1'",
    )
    .bind(format!("sha256:{}", "1".repeat(64)))
    .execute(db.pool())
    .await
    .expect("corrupt decision id within SQL shape");
    assert!(db.task_board_triage_current("item-1").await.is_err());
}
