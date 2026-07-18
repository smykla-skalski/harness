use std::collections::HashMap;

use tempfile::{TempDir, tempdir};

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction};
use crate::daemon::task_board_managed_agents::managed_worker_id;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, build_dispatch_plans_with_policy};

use super::admission_dispatch::{
    admission_policy, configure_policy, ledger_kind_state, preparing_intent, test_db,
};

#[tokio::test]
async fn worker_claim_renewal_prevents_reclaim() {
    let (_dir, db, claim) = claimed_dispatch("task-worker-claim-renewal").await;
    age_claim(&db, &claim.intent_id).await;

    db.renew_task_board_dispatch_claim(&claim.intent_id, &claim.claim_token)
        .await
        .expect("renew worker claim");

    assert!(
        db.claim_next_task_board_dispatch()
            .await
            .expect("check renewed worker claim")
            .is_none(),
        "a live worker heartbeat must prevent concurrent reclamation",
    );
}

#[tokio::test]
async fn stale_worker_claim_cannot_mutate_reclaimed_claim() {
    let (_dir, db, first) = claimed_dispatch("task-worker-claim-stale").await;
    age_claim(&db, &first.intent_id).await;
    let reclaimed = db
        .claim_next_task_board_dispatch()
        .await
        .expect("reclaim worker dispatch")
        .expect("expired worker claim");
    assert_ne!(reclaimed.claim_token, first.claim_token);

    db.renew_task_board_dispatch_claim(&first.intent_id, &first.claim_token)
        .await
        .expect_err("stale token must not renew the reclaimed worker claim");
    db.complete_task_board_dispatch(&first.intent_id, &first.claim_token, "codex-stale-worker")
        .await
        .expect_err("stale token must not complete the reclaimed worker claim");

    let (status, claim_token): (String, Option<String>) = sqlx::query_as(
        "SELECT status, claim_token FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(&first.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load reclaimed worker claim");
    assert_eq!(status, "starting");
    assert_eq!(claim_token.as_deref(), Some(reclaimed.claim_token.as_str()));
}

#[tokio::test]
async fn reclaimed_worker_restores_expired_frozen_admission_before_commit() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(2)).await;
    let first_intent = prepare_admitted_dispatch(&db, "reclaimed-worker-first").await;
    let first = db
        .claim_task_board_dispatch("reclaimed-worker-first")
        .await
        .expect("claim first dispatch")
        .expect("pending first dispatch");
    assert!(matches!(first.action, TaskBoardDispatchClaimAction::Start));
    let _second_intent = prepare_admitted_dispatch(&db, "reclaimed-worker-second").await;
    configure_policy(&db, admission_policy(1)).await;
    db.update_task_board_item("reclaimed-worker-first", |item| {
        item.title = "Edited after uncertain start".to_owned();
        Ok(true)
    })
    .await
    .expect("edit non-frozen item metadata");
    age_claim_and_release_admission(&db, &first.intent_id).await;

    let reclaimed = db
        .claim_task_board_dispatch("reclaimed-worker-first")
        .await
        .expect("reclaim uncertain dispatch")
        .expect("expired dispatch claim");

    assert_eq!(reclaimed.intent_id, first_intent);
    assert!(matches!(
        reclaimed.action,
        TaskBoardDispatchClaimAction::Recover
    ));
    let worker_id = managed_worker_id(&reclaimed.applied, &reclaimed.intent_id);
    db.renew_task_board_dispatch_claim(&reclaimed.intent_id, &reclaimed.claim_token)
        .await
        .expect("restore the deterministic worker's frozen admission");
    db.complete_task_board_dispatch(&reclaimed.intent_id, &reclaimed.claim_token, &worker_id)
        .await
        .expect("commit deterministic worker evidence under frozen admission");
    assert_eq!(
        ledger_kind_state(&db, &reclaimed.intent_id, "concurrency").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(&db, &reclaimed.intent_id, "rate").await,
        "committed"
    );
}

#[tokio::test]
async fn first_worker_claim_still_revalidates_after_preparation_attempts() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(2)).await;
    let first_intent = prepare_admitted_dispatch(&db, "first-worker-revalidation").await;
    let _second_intent = prepare_admitted_dispatch(&db, "first-worker-competitor").await;
    configure_policy(&db, admission_policy(1)).await;

    let error = db
        .claim_task_board_dispatch("first-worker-revalidation")
        .await
        .expect_err("a normal first worker claim must revalidate current policy");

    assert!(error.to_string().contains("admission deferred"));
    assert_eq!(
        ledger_kind_state(&db, &first_intent, "concurrency").await,
        "released"
    );
}

#[tokio::test]
async fn completed_lookup_requires_the_exact_workflow_execution() {
    let (_dir, db, claim) = claimed_dispatch("task-worker-completed-identity").await;
    db.complete_task_board_dispatch(&claim.intent_id, &claim.claim_token, "codex-completed")
        .await
        .expect("complete worker dispatch");

    assert!(
        db.task_board_dispatch_is_completed(&claim.applied)
            .await
            .expect("check completed dispatch")
    );
    let mut different_execution = claim.applied;
    different_execution.item.workflow.execution_id = Some("workflow-different".to_string());
    assert!(
        !db.task_board_dispatch_is_completed(&different_execution)
            .await
            .expect("check mismatched workflow execution")
    );
}

#[tokio::test]
async fn crash_reclaims_compensation_without_restarting_or_completing_worker() {
    let (_dir, db, first) = claimed_dispatch("task-worker-compensation-reclaim").await;
    db.begin_task_board_dispatch_compensation(
        &first.intent_id,
        &first.claim_token,
        "codex-compensation-reclaim",
        "worker started but dispatch completion failed",
    )
    .await
    .expect("persist compensation before worker stop");
    db.complete_task_board_dispatch(&first.intent_id, &first.claim_token, "codex-invalid")
        .await
        .expect_err("compensating dispatch must never complete");
    age_claim(&db, &first.intent_id).await;

    let reclaimed = db
        .claim_next_task_board_dispatch()
        .await
        .expect("reclaim compensation")
        .expect("compensation remains recoverable");
    assert_ne!(reclaimed.claim_token, first.claim_token);
    assert!(matches!(
        &reclaimed.action,
        TaskBoardDispatchClaimAction::Compensate { reason }
            if reason == "worker started but dispatch completion failed"
    ));
    db.finalize_task_board_dispatch_compensation(
        &first.intent_id,
        &first.claim_token,
        "codex-compensation-reclaim",
        "worker started but dispatch completion failed",
    )
    .await
    .expect_err("stale worker claim cannot finalize compensation");
    db.finalize_task_board_dispatch_compensation(
        &reclaimed.intent_id,
        &reclaimed.claim_token,
        "codex-compensation-reclaim",
        "worker started but dispatch completion failed",
    )
    .await
    .expect("current worker claim finalizes compensation");

    let (status, marker, claim_token): (String, bool, Option<String>) = sqlx::query_as(
        "SELECT status, compensation_pending, claim_token
         FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(&reclaimed.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load finalized compensation");
    assert_eq!(status, "failed");
    assert!(!marker);
    assert!(claim_token.is_none());
    let item = db
        .task_board_item("task-worker-compensation-reclaim")
        .await
        .expect("load compensated item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert!(item.session_id.is_none());
}

#[tokio::test]
async fn compensation_renewal_ignores_broken_start_admission_evidence() {
    let (_dir, db, claim) = claimed_dispatch("task-worker-compensation-admission").await;
    db.begin_task_board_dispatch_compensation(
        &claim.intent_id,
        &claim.claim_token,
        "codex-compensation-admission",
        "worker stop required",
    )
    .await
    .expect("persist compensation marker");
    insert_unowned_admission_reservation(&db, &claim).await;

    db.renew_task_board_dispatch_claim(&claim.intent_id, &claim.claim_token)
        .await
        .expect("compensation renewal must not re-enter start admission");
}

async fn claimed_dispatch(item_id: &str) -> (TempDir, AsyncDaemonDb, ClaimedTaskBoardDispatch) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Worker claim".to_owned(),
        "Body".to_owned(),
        "2026-07-17T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");
    let item = db.task_board_item(item_id).await.expect("load item");
    let lifecycle = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch(item_id, "session-1", "work-1", &lifecycle)
        .await
        .expect("enqueue worker dispatch");
    let claim = db
        .claim_task_board_dispatch(item_id)
        .await
        .expect("claim worker dispatch")
        .expect("pending worker dispatch");
    (dir, db, claim)
}

async fn prepare_admitted_dispatch(db: &AsyncDaemonDb, item_id: &str) -> String {
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Admitted worker claim".to_owned(),
        "Body".to_owned(),
        "2026-07-17T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create admitted item");
    let item = db
        .task_board_item(item_id)
        .await
        .expect("load admitted item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve admitted dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim admitted preparation")
        .expect("pending admitted preparation");
    db.complete_task_board_dispatch_preparation(&preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete admitted preparation");
    intent
}

async fn age_claim(db: &AsyncDaemonDb, intent_id: &str) {
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '1970-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("age worker claim");
}

async fn age_claim_and_release_admission(db: &AsyncDaemonDb, intent_id: &str) {
    age_claim(db, intent_id).await;
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', expires_at = NULL,
             released_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("release admission beyond its reservation horizon");
}

async fn insert_unowned_admission_reservation(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
) {
    let now = "2026-07-17T10:00:00Z";
    let expires = "2099-07-17T10:15:00Z";
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision,
             settings_revision, decision, policy_json, context_json,
             requirements_json, blockers_json, launch_profile, evaluated_at,
             next_available_at, is_current, superseded_at, created_at
         ) VALUES (
             'orphaned-compensation-decision', ?1, 99, ?2, 1, 1, 'allowed',
             '{}', '{}', '[]', '[]', 'workspace_write', ?3, NULL, 0, ?3, ?3
         )",
    )
    .bind(&claim.intent_id)
    .bind(&claim.applied.board_item_id)
    .bind(now)
    .execute(db.pool())
    .await
    .expect("insert non-current admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value,
             window_started_at, window_ends_at, state, managed_worker_id,
             expires_at, reserved_at, committed_at, released_at
         ) VALUES (
             'orphaned-compensation-ledger', 'orphaned-compensation-decision',
             'allowed', ?1, 99, ?2, 'concurrency:global', 'concurrency',
             'global', 1, 1, NULL, NULL, 'reserved', NULL, ?3, ?4, NULL, NULL
         )",
    )
    .bind(&claim.intent_id)
    .bind(&claim.applied.board_item_id)
    .bind(expires)
    .bind(now)
    .execute(db.pool())
    .await
    .expect("insert unowned admission reservation");
}
