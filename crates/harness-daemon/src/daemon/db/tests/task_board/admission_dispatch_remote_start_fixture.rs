use super::*;
use crate::task_board::{
    TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
};

pub(crate) struct PreparedRemoteOffer {
    pub(crate) db: TestDb,
    pub(crate) intent: String,
    pub(crate) execution_id: String,
    pub(crate) execution: TaskBoardWorkflowExecutionRecord,
    pub(crate) attempt: TaskBoardExecutionAttemptRecord,
    pub(crate) offer: RemoteOfferRequest,
}

pub(crate) async fn prepare_remote_offer(item_id: &str) -> PreparedRemoteOffer {
    prepare_remote_offer_with_policy(item_id, false).await
}

pub(crate) async fn prepare_remote_offer_with_policy(
    item_id: &str,
    configure_admission: bool,
) -> PreparedRemoteOffer {
    prepare_remote_offer_with_retry(item_id, configure_admission, None).await
}

pub(crate) async fn prepare_remote_offer_with_retry(
    item_id: &str,
    configure_admission: bool,
    retry_max_attempts: Option<u32>,
) -> PreparedRemoteOffer {
    let db = configured_remote_test_db(configure_admission, retry_max_attempts).await;
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Review exact remote head".into(),
        "Freeze unconfigured admission before remote I/O".into(),
        "2026-07-19T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    item.execution_repository = Some("example/harness".into());
    db.create_task_board_item(item).await.expect("create item");
    let mut launch = read_only_launch(&db, Some("example/harness")).await;
    let plan = create_plan_for_existing(&db, item_id).await;
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
    let item_snapshot = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("source item snapshot");
    launch.source_item_revision = item_snapshot.item_revision;
    launch.prepared_item_revision = item_snapshot.item_revision;
    launch.run_context.session_id = preparation.preparation.session_id.clone();
    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
            None,
        )
        .await
        .expect("complete preparation");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("execution id");
    let claim = db
        .claim_task_board_dispatch(item_id)
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    db.prepare_task_board_workflow_dispatch(&intent, &claim.claim_token)
        .await
        .expect("prepare workflow");
    normalize_prepared_times(&db, &execution_id).await;
    let execution = db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load execution")
        .expect("execution");
    let attempt = execution.attempts[0].clone();
    let offer = remote_offer(&execution, &attempt);
    PreparedRemoteOffer {
        db,
        intent,
        execution_id,
        execution,
        attempt,
        offer,
    }
}

async fn normalize_prepared_times(db: &AsyncDaemonDb, execution_id: &str) {
    sqlx::query(
        "UPDATE task_board_workflow_executions
         SET created_at = '2026-07-19T10:00:00Z', updated_at = '2026-07-19T10:00:00Z'
         WHERE execution_id = ?1",
    )
    .bind(&execution_id)
    .execute(db.pool())
    .await
    .expect("normalize prepared execution time");
    sqlx::query(
        "UPDATE task_board_execution_attempts
         SET started_at = '2026-07-19T10:00:00Z', updated_at = '2026-07-19T10:00:00Z'
         WHERE execution_id = ?1",
    )
    .bind(&execution_id)
    .execute(db.pool())
    .await
    .expect("normalize prepared attempt time");
}
