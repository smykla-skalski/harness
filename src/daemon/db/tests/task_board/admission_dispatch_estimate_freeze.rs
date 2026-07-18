use super::{
    admission_policy, configure_policy, create_plan, current_generation, ledger_kind_state,
    ledger_state_count, preparing_intent, test_db,
};
use crate::daemon::db::complete_write_preparation;
use crate::task_board::{
    AgentMode, TaskBoardLaunchCapability, TaskBoardStatus, TaskBoardWorkflowStatus,
};

#[tokio::test]
async fn admission_revalidates_then_commits_and_releases_concurrency() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-start", AgentMode::Headless).await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );

    configure_policy(&db, admission_policy(2)).await;
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    assert_eq!(current_generation(&db, &intent).await, 2);
    complete_write_preparation(&db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
    let claim = db
        .claim_task_board_dispatch("admission-start")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    assert_eq!(current_generation(&db, &intent).await, 3);
    let error = db
        .update_task_board_item("admission-start", |item| {
            item.estimated_tokens = Some(10);
            Ok(true)
        })
        .await
        .expect_err("worker claim must freeze estimate edits");
    assert!(
        error
            .to_string()
            .contains("cannot change while its workflow side effect is claimed")
    );
    assert_eq!(
        db.task_board_item("admission-start")
            .await
            .expect("reload frozen item")
            .estimated_tokens,
        None
    );
    db.validate_task_board_dispatch_admission_start(
        &intent,
        &claim.claim_token,
        Some(TaskBoardLaunchCapability::WorkspaceWrite),
        None,
    )
    .await
    .expect("validate launch");
    db.complete_task_board_dispatch(&intent, &claim.claim_token, "codex-admission-start")
        .await
        .expect("commit launch");
    assert_eq!(ledger_state_count(&db, &intent, "committed").await, 2);
    let error = db
        .update_task_board_item("admission-start", |item| {
            item.status = TaskBoardStatus::Done;
            Ok(true)
        })
        .await
        .expect_err("active worker must prevent terminal item mutation");
    assert!(error.to_string().contains("managed worker is active"));

    assert!(
        db.release_task_board_admission_for_managed_worker("codex-admission-start")
            .await
            .expect("release terminal worker")
    );
    assert_eq!(
        ledger_kind_state(&db, &intent, "concurrency").await,
        "released"
    );
    assert_eq!(ledger_kind_state(&db, &intent, "rate").await, "committed");
    db.update_task_board_item("admission-start", |item| {
        item.status = TaskBoardStatus::Done;
        Ok(true)
    })
    .await
    .expect("terminal item update after worker release");
}

#[tokio::test]
async fn estimates_remain_frozen_after_started_worker_becomes_terminal() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-terminal-estimate", AgentMode::Headless).await;
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
        .claim_task_board_dispatch("admission-terminal-estimate")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    db.validate_task_board_dispatch_admission_start(
        &intent,
        &claim.claim_token,
        Some(TaskBoardLaunchCapability::WorkspaceWrite),
        None,
    )
    .await
    .expect("validate launch");
    let worker_id = "codex-admission-terminal-estimate";
    db.complete_task_board_dispatch(&intent, &claim.claim_token, worker_id)
        .await
        .expect("complete dispatch");
    assert!(
        db.release_task_board_admission_for_managed_worker(worker_id)
            .await
            .expect("release worker admission")
    );
    db.update_task_board_item("admission-terminal-estimate", |item| {
        item.status = TaskBoardStatus::Done;
        item.workflow.status = TaskBoardWorkflowStatus::Completed;
        Ok(true)
    })
    .await
    .expect("make item terminal");
    let before = db
        .task_board_item_snapshot("admission-terminal-estimate")
        .await
        .expect("load terminal item");

    let error = db
        .update_task_board_item("admission-terminal-estimate", |item| {
            item.estimated_tokens = Some(10);
            Ok(true)
        })
        .await
        .expect_err("started worker must freeze terminal item estimates");

    assert!(error.to_string().contains("frozen after worker start"));
    let after = db
        .task_board_item_snapshot("admission-terminal-estimate")
        .await
        .expect("reload terminal item");
    assert_eq!(after.item_revision, before.item_revision);
    assert_eq!(after.item.estimated_tokens, before.item.estimated_tokens);
}
