use super::*;
use crate::task_board::{
    TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardLaunchCapability,
    TaskBoardReadOnlyRunContext,
};

#[tokio::test]
async fn read_only_completion_rechecks_configuration_before_mutation_and_can_compensate() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let item_id = "completion-configuration-fence";
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Review exact head".into(),
        "Review without workspace writes".into(),
        "2026-07-18T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    db.create_task_board_item(item).await.expect("create item");
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(
            &create_plan_for_existing(&db, item_id).await,
            "control-plane",
            Some("/tmp/project"),
            false,
        )
        .await
        .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    let launch = read_only_launch(&db, item_id, &preparation.preparation.session_id).await;
    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
            None,
        )
        .await
        .expect("publish read-only launch");
    let launch = applied
        .read_only_workflow
        .as_ref()
        .expect("published read-only launch");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("workflow execution id");
    let claim = db
        .claim_task_board_dispatch(item_id)
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    db.validate_task_board_dispatch_admission_start(
        &intent,
        &claim.claim_token,
        Some(TaskBoardLaunchCapability::ReportReadOnly),
        Some((launch.prepared_item_revision, launch.configuration_revision)),
    )
    .await
    .expect("authorize stable read-only start");
    let item_before_completion = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("item before completion");
    assert_configuration_revision_aba(&db).await;
    let admission_owner = workflow_owner(execution_id);
    let side_effect_worker_id = format!("codex-{intent}");

    let error = db
        .complete_task_board_dispatch(&intent, &claim.claim_token, &admission_owner)
        .await
        .expect_err("configuration drift must refuse dispatch completion");

    assert!(
        error
            .to_string()
            .contains("configuration revision changed before worker start")
    );
    let item_after_completion = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("item after refused completion");
    assert_eq!(
        item_after_completion.item_revision,
        item_before_completion.item_revision
    );
    assert_eq!(item_after_completion.item, item_before_completion.item);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(ledger_state_count(&db, &intent, "reserved").await, 2);
    assert_eq!(ledger_state_count(&db, &intent, "committed").await, 0);
    assert_eq!(intent_status(&db, &intent).await, "starting");

    db.begin_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        &side_effect_worker_id,
        "configuration drift after external start",
    )
    .await
    .expect("persist compensation after refused completion");
    db.finalize_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        &side_effect_worker_id,
        "configuration drift after external start",
    )
    .await
    .expect("finalize compensation after worker stop");
    assert_eq!(
        ledger_kind_state(&db, &intent, "concurrency").await,
        "released"
    );
    assert_eq!(ledger_kind_state(&db, &intent, "rate").await, "committed");
    assert_eq!(intent_status(&db, &intent).await, "failed");
}

async fn read_only_launch(
    db: &AsyncDaemonDb,
    item_id: &str,
    session_id: &str,
) -> TaskBoardReadOnlyWorkflowLaunch {
    let snapshot = db
        .task_board_item_snapshot(item_id)
        .await
        .expect("source item snapshot");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("resolved reviewers"),
        source_item_revision: snapshot.item_revision,
        prepared_item_revision: snapshot.item_revision,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: session_id.into(),
            title: snapshot.item.title,
            body: snapshot.item.body,
            tags: snapshot.item.tags,
            worktree: "/tmp/worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: "1111111111111111111111111111111111111111".into(),
    }
}

async fn assert_configuration_revision_aba(db: &AsyncDaemonDb) {
    let before = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load settings snapshot");
    let mut changed = before.settings.clone();
    changed.policy_version = "policy-after-worker-start".into();
    db.replace_task_board_orchestrator_settings(&changed)
        .await
        .expect("persist transient settings");
    db.replace_task_board_orchestrator_settings(&before.settings)
        .await
        .expect("restore original settings");
    let after = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load restored settings snapshot");
    assert_eq!(after.settings, before.settings);
    assert_eq!(after.row_revision, before.row_revision + 2);
}

async fn workflow_execution_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_workflow_executions")
        .fetch_one(db.pool())
        .await
        .expect("count workflow executions")
}

async fn intent_status(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load dispatch intent status")
}
