use std::collections::HashMap;

use crate::daemon::db::NewApprovalGrant;
use crate::daemon::db::task_board::write_workflow_fixture::{
    approved_write_item, complete_write_preparation,
};
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    PolicyAction, PolicyReasonCode, SpawnGateSwitches, TaskBoardItem,
    build_dispatch_plans_with_policy,
};

use super::admission_dispatch::{
    admission_policy, configure_policy, ledger_kind_state, preparing_intent, test_db,
};

#[tokio::test]
async fn missing_worker_compensation_commits_usage_and_releases_concurrency() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let item = approved_write_item(TaskBoardItem::new(
        "admission-compensated-start".to_string(),
        "Compensated admission".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    ));
    db.create_task_board_item(item).await.expect("create item");
    let item = db
        .task_board_item("admission-compensated-start")
        .await
        .expect("load item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
    let claim = db
        .claim_task_board_dispatch("admission-compensated-start")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let worker_id = "codex-admission-compensated-start";
    db.begin_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        worker_id,
        "dispatch completion failed",
    )
    .await
    .expect("persist compensation marker");

    db.finalize_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        worker_id,
        "dispatch completion failed",
    )
    .await
    .expect("finalize stopped worker compensation");

    assert_eq!(
        ledger_kind_state(&db, &intent, "concurrency").await,
        "released"
    );
    assert_eq!(ledger_kind_state(&db, &intent, "rate").await, "committed");
}

#[tokio::test]
async fn compensation_restart_accepts_terminal_release_and_retains_consumed_grant() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let fixture = begin_compensation_with_grant(&db, "admission-terminal-compensation").await;

    let pending_restart = db.reopen().await;
    assert!(
        pending_restart
            .task_board_admission_worker_recoveries()
            .await
            .expect("load pending compensation recoveries")
            .is_empty()
    );
    let mut run = super::super::sample_codex_run(&fixture.worker_id, "2026-07-17T10:00:00Z");
    run.status = CodexRunStatus::Failed;
    pending_restart
        .save_codex_run(&run)
        .await
        .expect("persist terminal worker");
    assert_eq!(
        ledger_kind_state(&pending_restart, &fixture.intent_id, "concurrency").await,
        "released"
    );
    assert_eq!(
        ledger_kind_state(&pending_restart, &fixture.intent_id, "rate").await,
        "committed"
    );
    pending_restart
        .finalize_task_board_dispatch_compensation(
            &fixture.intent_id,
            &fixture.claim_token,
            &fixture.worker_id,
            "dispatch completion failed",
        )
        .await
        .expect("finalize terminal worker compensation");
    drop(pending_restart);

    let finalized_restart = db.reopen().await;
    assert_finalized_compensation(&finalized_restart, &fixture).await;
}

struct CompensationFixture {
    intent_id: String,
    claim_token: String,
    grant_id: String,
    worker_id: String,
}

async fn begin_compensation_with_grant(
    db: &crate::daemon::db::AsyncDaemonDb,
    item_id: &str,
) -> CompensationFixture {
    let item = approved_write_item(TaskBoardItem::new(
        item_id.to_string(),
        "Terminal compensation".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    ));
    db.create_task_board_item(item).await.expect("create item");
    let grant = approved_grant(&db, item_id).await;
    let mut plan = build_dispatch_plans_with_policy(
        &[db.task_board_item(item_id).await.expect("load item")],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    plan.consumed_approval_grant_id = Some(grant.id.clone());
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    complete_write_preparation(db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
    let claim = db
        .claim_task_board_dispatch(item_id)
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    assert_eq!(
        claim.consumed_approval_grant_id.as_deref(),
        Some(grant.id.as_str())
    );
    let worker_id = format!("codex-{intent}");
    db.begin_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        &worker_id,
        "dispatch completion failed",
    )
    .await
    .expect("persist compensation marker");
    CompensationFixture {
        intent_id: intent,
        claim_token: claim.claim_token,
        grant_id: grant.id,
        worker_id,
    }
}

async fn assert_finalized_compensation(
    db: &crate::daemon::db::AsyncDaemonDb,
    fixture: &CompensationFixture,
) {
    assert!(
        db.task_board_admission_worker_recoveries()
            .await
            .expect("load finalized compensation recoveries")
            .is_empty()
    );
    let (status, compensation_pending): (String, bool) = sqlx::query_as(
        "SELECT status, compensation_pending FROM task_board_dispatch_intents
         WHERE intent_id = ?1",
    )
    .bind(&fixture.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load finalized intent");
    assert_eq!(status, "failed");
    assert!(!compensation_pending);
    assert_eq!(
        ledger_kind_state(db, &fixture.intent_id, "concurrency").await,
        "released"
    );
    assert_eq!(
        ledger_kind_state(db, &fixture.intent_id, "rate").await,
        "committed"
    );
    let consumed_at: Option<String> =
        sqlx::query_scalar("SELECT consumed_at FROM policy_approval_grants WHERE id = ?1")
            .bind(&fixture.grant_id)
            .fetch_one(db.pool())
            .await
            .expect("load compensated approval grant");
    assert!(
        consumed_at.is_some(),
        "compensation refunded a used one-shot grant"
    );
}

async fn approved_grant(
    db: &crate::daemon::db::AsyncDaemonDb,
    item_id: &str,
) -> crate::task_board::PolicyApprovalGrant {
    let grant = db
        .ensure_pending_approval_grant(&NewApprovalGrant {
            board_item_id: item_id.to_string(),
            action: PolicyAction::SpawnAgent,
            canvas_id: None,
            canvas_revision: 1,
            node_id: "approve-spawn".to_string(),
            reason_code: PolicyReasonCode::ApprovalRequired,
            expiry_seconds: None,
        })
        .await
        .expect("create approval grant");
    db.resolve_approval_grant(&grant.id, true, "operator")
        .await
        .expect("approve grant")
}
