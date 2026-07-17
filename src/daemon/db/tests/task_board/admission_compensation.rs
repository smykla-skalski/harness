use std::collections::HashMap;

use crate::task_board::{
    AgentMode, SpawnGateSwitches, TaskBoardItem, build_dispatch_plans_with_policy,
};

use super::admission_dispatch::{
    admission_policy, configure_policy, ledger_kind_state, preparing_intent, test_db,
};

#[tokio::test]
async fn missing_worker_compensation_commits_usage_and_releases_concurrency() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let mut item = TaskBoardItem::new(
        "admission-compensated-start".to_string(),
        "Compensated admission".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    );
    item.agent_mode = AgentMode::Headless;
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
    db.complete_task_board_dispatch_preparation(&preparation, "branch", "/tmp/worktree")
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
        claim.consumed_approval_grant_id.as_deref(),
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
