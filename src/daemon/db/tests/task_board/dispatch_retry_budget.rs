use std::collections::HashMap;

use sqlx::{query, query_as};
use tempfile::tempdir;

use crate::daemon::db::{
    AsyncDaemonDb, ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch,
    TASK_BOARD_PREPARATION_MAX_ATTEMPTS,
};
use crate::task_board::{
    SpawnGateSwitches, TaskBoardItem, TaskBoardStatus, build_dispatch_plans_with_policy,
};

/// Bounds every give-up loop below. Without it a preparation that never stops
/// retrying hangs the test run instead of failing it.
const RELEASE_LIMIT: usize = 200;

struct IntentRow {
    status: String,
    attempts: i64,
    retry_delay_seconds: i64,
    last_error: Option<String>,
}

async fn intent_row(db: &AsyncDaemonDb, intent_id: &str) -> IntentRow {
    let row = query_as::<_, (String, i64, i64, Option<String>)>(
        "SELECT status, attempts,
                CAST(strftime('%s', available_at) - strftime('%s', updated_at) AS INTEGER),
                last_error
         FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load intent row");
    IntentRow {
        status: row.0,
        attempts: row.1,
        retry_delay_seconds: row.2,
        last_error: row.3,
    }
}

async fn reserve_preparing(db: &AsyncDaemonDb, item_id: &str) -> String {
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Retry budget".to_owned(),
        "Body".to_owned(),
        "2026-07-27T06:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");
    let plan = build_dispatch_plans_with_policy(
        &[db.task_board_item(item_id).await.expect("load item")],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    match db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatch")
    {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("reservation already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => panic!("reservation blocked"),
    }
}

/// Moves the retry window into the past so the next claim can proceed without
/// waiting out the backoff this test is measuring.
async fn expire_backoff(db: &AsyncDaemonDb, intent_id: &str) {
    query(
        "UPDATE task_board_dispatch_intents
         SET available_at = datetime('now', '-1 hour') WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("expire backoff");
}

/// Claims the preparation and releases it as failed, returning the row that left.
async fn fail_once(db: &AsyncDaemonDb, intent_id: &str) -> IntentRow {
    expire_backoff(db, intent_id).await;
    let claim: ClaimedTaskBoardDispatchPreparation = db
        .claim_task_board_dispatch_preparation(intent_id)
        .await
        .expect("claim preparation")
        .expect("claimable preparation");
    db.release_task_board_dispatch_preparation(&claim, "worktree is unreadable")
        .await
        .expect("release preparation");
    intent_row(db, intent_id).await
}

async fn test_db() -> (AsyncDaemonDb, tempfile::TempDir) {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("open db");
    (db, directory)
}

#[tokio::test]
async fn each_failed_attempt_waits_longer_than_the_last() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "retry-backoff").await;

    let first = fail_once(&db, &intent).await;
    let second = fail_once(&db, &intent).await;
    let third = fail_once(&db, &intent).await;

    assert_eq!(first.status, "preparing");
    assert!(
        first.retry_delay_seconds < second.retry_delay_seconds
            && second.retry_delay_seconds < third.retry_delay_seconds,
        "a repeating failure must wait longer each time, got {} then {} then {}",
        first.retry_delay_seconds,
        second.retry_delay_seconds,
        third.retry_delay_seconds
    );
}

#[tokio::test]
async fn a_preparation_stops_retrying_once_its_budget_is_spent() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "retry-budget").await;

    let mut row = fail_once(&db, &intent).await;
    let mut releases = 1;
    while row.status == "preparing" && releases < RELEASE_LIMIT {
        row = fail_once(&db, &intent).await;
        releases += 1;
    }

    assert_eq!(
        row.status, "failed",
        "a preparation that never succeeds must stop retrying, still going after {releases} releases"
    );
    assert!(
        row.last_error
            .as_deref()
            .is_some_and(|error| error.contains("worktree is unreadable")),
        "the terminal record must carry the failure that caused it, got {:?}",
        row.last_error
    );
    assert_eq!(
        row.attempts, TASK_BOARD_PREPARATION_MAX_ATTEMPTS,
        "the budget must be spent exactly, not overshot or cut short"
    );
}

#[tokio::test]
async fn an_exhausted_preparation_releases_its_item() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "retry-release").await;

    let mut row = fail_once(&db, &intent).await;
    let mut releases = 1;
    while row.status == "preparing" && releases < RELEASE_LIMIT {
        row = fail_once(&db, &intent).await;
        releases += 1;
    }
    assert_ne!(
        row.status, "preparing",
        "the preparation never gave up within {RELEASE_LIMIT} releases"
    );

    let item = db
        .task_board_item("retry-release")
        .await
        .expect("load item");
    assert_eq!(
        item.status,
        TaskBoardStatus::Todo,
        "an item whose dispatch gave up must be dispatchable again"
    );
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let retry = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve after exhaustion");
    match retry {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => {
            assert_ne!(intent_id, intent, "a retry must not reuse the dead intent");
        }
        ReservedTaskBoardDispatch::Applied(_) | ReservedTaskBoardDispatch::Blocked(_) => {
            panic!("an exhausted intent must not block a fresh reservation")
        }
    }
}
