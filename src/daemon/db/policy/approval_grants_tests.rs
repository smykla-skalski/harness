use std::collections::HashMap;

use tempfile::{TempDir, tempdir};

use super::*;
use crate::daemon::db::ReservedTaskBoardDispatch;
use crate::task_board::{
    PolicyAction, PolicyApprovalState, PolicyReasonCode, TaskBoardItem, TaskBoardStatus,
    build_dispatch_plans_with_policy,
};

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect async daemon db");
    (dir, db)
}

async fn consume(db: &AsyncDaemonDb, id: &str) -> bool {
    let mut transaction = db.pool().begin().await.expect("begin tx");
    let consumed = consume_approval_grant_in_tx(&mut *transaction, id)
        .await
        .expect("consume in tx");
    transaction.commit().await.expect("commit tx");
    consumed
}

fn sample_grant() -> NewApprovalGrant {
    NewApprovalGrant {
        board_item_id: "board-item-1".to_owned(),
        action: PolicyAction::SpawnAgent,
        canvas_id: Some("canvas-1".to_owned()),
        canvas_revision: 7,
        node_id: "approval-gate-1".to_owned(),
        reason_code: PolicyReasonCode::ApprovalRequired,
        expiry_seconds: Some(3600),
    }
}

#[tokio::test]
async fn ensure_pending_is_idempotent_on_the_live_key() {
    let (_dir, db) = connect().await;
    let first = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create pending grant");
    assert_eq!(first.state, PolicyApprovalState::Pending);
    assert_eq!(first.canvas_revision, 7);
    assert_eq!(first.reason_code, PolicyReasonCode::ApprovalRequired);

    let second = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("reuse live grant");
    assert_eq!(second.id, first.id, "same live key returns the same grant");

    let pending = db
        .list_pending_approval_grants()
        .await
        .expect("list pending");
    assert_eq!(pending.len(), 1, "no duplicate live grant is created");
}

#[tokio::test]
async fn a_fresh_grant_is_created_after_consumption() {
    let (_dir, db) = connect().await;
    let grant = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create");
    db.resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve");
    assert!(
        consume(&db, &grant.id).await,
        "approved grant consumes once"
    );

    let reborn = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create after consume");
    assert_ne!(reborn.id, grant.id, "a new grant is minted after consume");
    assert_eq!(reborn.state, PolicyApprovalState::Pending);
}

#[tokio::test]
async fn approve_then_consume_is_one_shot() {
    let (_dir, db) = connect().await;
    let grant = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create");
    let resolved = db
        .resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve");
    assert_eq!(resolved.state, PolicyApprovalState::Approved);
    assert_eq!(resolved.resolved_by.as_deref(), Some("operator"));

    assert!(consume(&db, &grant.id).await, "first consume transitions");
    assert!(!consume(&db, &grant.id).await, "second consume is a no-op");
    assert!(
        db.live_approval_grant("board-item-1", PolicyAction::SpawnAgent, 7)
            .await
            .expect("live lookup")
            .is_none(),
        "a consumed grant is no longer live"
    );
}

#[tokio::test]
async fn a_denied_grant_cannot_be_consumed() {
    let (_dir, db) = connect().await;
    let grant = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create");
    let resolved = db
        .resolve_approval_grant(&grant.id, false, "operator")
        .await
        .expect("deny");
    assert_eq!(resolved.state, PolicyApprovalState::Denied);
    assert!(
        !consume(&db, &grant.id).await,
        "a denied grant does not consume"
    );
}

#[tokio::test]
async fn resolving_a_missing_grant_errors() {
    let (_dir, db) = connect().await;
    let error = db
        .resolve_approval_grant("policy-grant-missing", true, "operator")
        .await
        .expect_err("missing grant errors");
    assert!(
        error.to_string().contains("not pending or does not exist"),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn consume_in_tx_matches_the_pooled_consume() {
    let (_dir, db) = connect().await;
    let grant = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create");
    db.resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve");

    let mut transaction = db.pool().begin().await.expect("begin tx");
    let consumed = consume_approval_grant_in_tx(&mut *transaction, &grant.id)
        .await
        .expect("consume in tx");
    transaction.commit().await.expect("commit tx");
    assert!(consumed, "in-tx consume transitions the approved grant");

    let after = db
        .approval_grant(&grant.id)
        .await
        .expect("read")
        .expect("grant present");
    assert!(after.consumed_at.is_some(), "consumed_at is stamped");
}

#[tokio::test]
async fn stale_consumed_grant_prevents_dispatch_preparation_completion() {
    let (_dir, db) = connect().await;
    let item_id = "board-item-1";
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Stale grant dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-14T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");
    let grant = db
        .ensure_pending_approval_grant(&sample_grant())
        .await
        .expect("create grant");
    db.resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve grant");

    let item = db.task_board_item(item_id).await.expect("load item");
    let mut plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    plan.consumed_approval_grant_id = Some(grant.id.clone());
    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", None, false)
        .await
        .expect("reserve dispatch");
    let intent_id = match reserved {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation was already applied"),
    };
    let claim = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    assert!(consume(&db, &grant.id).await, "race consumes grant first");

    let error = db
        .complete_task_board_dispatch_preparation(&claim, "harness/stale", "/tmp/stale")
        .await
        .expect_err("stale grant must reject completion");
    assert!(
        error.message().contains("approval grant already consumed"),
        "unexpected error: {error:?}"
    );

    let published_intents: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status IN ('held', 'pending', 'starting')",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count published intents");
    assert_eq!(published_intents, 0, "stale grant must publish no intent");
    let unchanged = db.task_board_item(item_id).await.expect("reload item");
    assert_eq!(unchanged.status, TaskBoardStatus::Todo);
    assert!(unchanged.session_id.is_none());
    assert!(unchanged.work_item_id.is_none());
}
