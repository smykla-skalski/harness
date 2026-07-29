use std::collections::HashMap;

use sqlx::query;
use tempfile::tempdir;

use crate::daemon::db::{
    AsyncDaemonDb, ReservedTaskBoardDispatch, TASK_BOARD_PREPARATION_MAX_ATTEMPTS,
    TaskBoardPreparationClaim, TaskBoardPreparationUnavailable,
};
use crate::task_board::{SpawnGateSwitches, TaskBoardItem, build_dispatch_plans_with_policy};

async fn test_db() -> (AsyncDaemonDb, tempfile::TempDir) {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("open db");
    (db, directory)
}

async fn reserve_preparing(db: &AsyncDaemonDb, item_id: &str) -> String {
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Claim reason".to_owned(),
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

async fn unavailable_reason(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> TaskBoardPreparationUnavailable {
    match db
        .attempt_task_board_dispatch_preparation_claim(intent_id)
        .await
        .expect("attempt claim")
    {
        TaskBoardPreparationClaim::Unavailable(reason) => reason,
        TaskBoardPreparationClaim::Claimed(_) => panic!("preparation was claimable"),
    }
}

/// Pushes the retry window well past the second-level clock the claim compares
/// against, so the test reads a preparation that is unambiguously waiting.
async fn hold_off_retry(db: &AsyncDaemonDb, intent_id: &str) {
    set_available_at(db, intent_id, "+120 seconds").await;
}

/// The inverse: moves the retry window into the past so the next claim can
/// proceed without waiting out a backoff this test is not measuring.
async fn expire_backoff(db: &AsyncDaemonDb, intent_id: &str) {
    set_available_at(db, intent_id, "-1 hour").await;
}

async fn set_available_at(db: &AsyncDaemonDb, intent_id: &str, offset: &str) {
    query(
        "UPDATE task_board_dispatch_intents
         SET available_at = datetime('now', ?2) WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .bind(offset)
    .execute(db.pool())
    .await
    .expect("move retry window");
}

#[tokio::test]
async fn a_retrying_preparation_reports_the_failure_that_re_armed_it() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "claim-retrying").await;
    let claim = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("claimable preparation");
    db.release_task_board_dispatch_preparation(&claim, "worktree is unreadable")
        .await
        .expect("release preparation");
    hold_off_retry(&db, &intent).await;

    match unavailable_reason(&db, &intent).await {
        TaskBoardPreparationUnavailable::WaitingToRetry {
            seconds_remaining,
            last_error,
        } => {
            assert!(
                seconds_remaining > 0,
                "a preparation inside its backoff must report the wait, got {seconds_remaining}"
            );
            assert_eq!(
                last_error.as_deref(),
                Some("worktree is unreadable"),
                "the retry must carry the failure that caused it"
            );
        }
        other => panic!("a re-armed preparation must report its retry, got {other:?}"),
    }
}

#[tokio::test]
async fn a_claimed_preparation_reports_the_worker_holding_it() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "claim-held").await;
    let _held = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("claimable preparation");

    assert_eq!(
        unavailable_reason(&db, &intent).await,
        TaskBoardPreparationUnavailable::HeldByWorker,
        "a live claim is the one case that really is already in progress"
    );
}

#[tokio::test]
async fn a_settled_preparation_reports_the_status_it_moved_to() {
    let (db, _directory) = test_db().await;
    let intent = reserve_preparing(&db, "claim-settled").await;
    for _ in 0..TASK_BOARD_PREPARATION_MAX_ATTEMPTS {
        expire_backoff(&db, &intent).await;
        let claim = db
            .claim_task_board_dispatch_preparation(&intent)
            .await
            .expect("claim preparation")
            .expect("claimable preparation");
        db.release_task_board_dispatch_preparation(&claim, "worktree is unreadable")
            .await
            .expect("release preparation");
    }

    match unavailable_reason(&db, &intent).await {
        TaskBoardPreparationUnavailable::Settled { status } => assert_eq!(
            status, "failed",
            "a preparation that spent its budget must name where it went"
        ),
        other => panic!("a preparation past its budget must report as settled, got {other:?}"),
    }
}

#[tokio::test]
async fn an_unknown_preparation_reports_that_it_is_gone() {
    let (db, _directory) = test_db().await;

    assert_eq!(
        unavailable_reason(&db, "dispatch-intent-nonexistent").await,
        TaskBoardPreparationUnavailable::Missing,
        "an intent id with no row must not read as contention"
    );
}
