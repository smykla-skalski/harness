use super::*;
use crate::daemon::db::ClaimedTaskBoardDispatchPreparation;
use crate::task_board::{
    DispatchAppliedTask, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardWorkflowSnapshot,
};

const APPROVED_AT: &str = "2026-07-18T10:00:00Z";

#[tokio::test]
async fn write_dispatch_atomically_starts_approved_implementation() {
    let (db, intent, preparation, launch) = reserved_write("atomic-start").await;
    let source_revision = launch.source_item_revision;
    let applied = publish_write(&db, &preparation, launch).await;
    let published = applied.write_workflow.as_ref().expect("write launch");
    assert_eq!(published.prepared_item_revision, source_revision + 1);
    assert_eq!(published.planning_result.item_revision, source_revision + 2);
    assert_eq!(published.plan_approval.item_revision, source_revision + 2);
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("execution id");
    let claim = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim write dispatch")
        .expect("pending write dispatch");
    let owner = workflow_owner(&execution_id);

    db.complete_task_board_dispatch(&intent, &claim.claim_token, &owner)
        .await
        .expect("complete write dispatch");

    let execution = db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load execution")
        .expect("durable write execution");
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Implementation)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(execution.snapshot.item_revision, source_revision + 2);
    assert_eq!(
        execution.artifacts.planning_result,
        Some(published.planning_result.clone())
    );
    assert_eq!(
        execution.artifacts.plan_approval,
        Some(published.plan_approval.clone())
    );
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].action_key, "implementation:1");
    assert_eq!(
        execution.attempts[0].idempotency_key,
        format!("codex-{intent}")
    );
    assert_eq!(
        execution.ownership.resources.get("admission_owner"),
        Some(&owner)
    );
}

#[tokio::test]
async fn write_launch_rejects_item_revision_aba_before_pending_claim() {
    let (db, intent, preparation, launch) = reserved_write("revision-aba").await;
    let applied = publish_write(&db, &preparation, launch).await;
    for title in ["Transient title", "Implement approved plan"] {
        db.update_task_board_item(&applied.board_item_id, |item| {
            item.title = title.into();
            Ok(true)
        })
        .await
        .expect("mutate item")
        .expect("item mutation");
    }

    let error = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect_err("revision ABA must prevent write worker claim");

    assert!(error.to_string().contains("changed before worker claim"));
    assert_eq!(intent_status(&db, &intent).await, "failed");
    assert_eq!(workflow_execution_count(&db).await, 0);
}

#[tokio::test]
async fn write_completion_rejects_forged_persisted_plan_evidence_atomically() {
    let (db, intent, preparation, launch) = reserved_write("forged-plan").await;
    let applied = publish_write(&db, &preparation, launch).await;
    let claim = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim write dispatch")
        .expect("pending write dispatch");
    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET payload_json = json_set(
             payload_json,
             '$.write_workflow.planning_result.plan_markdown',
             '# Forged plan'
         )
         WHERE intent_id = ?1",
    )
    .bind(&intent)
    .execute(db.pool())
    .await
    .expect("forge persisted launch");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("execution id");

    let error = db
        .complete_task_board_dispatch(&intent, &claim.claim_token, &workflow_owner(execution_id))
        .await
        .expect_err("forged planning evidence must fail closed");

    assert!(error.to_string().contains("planning evidence changed"));
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &intent).await, "starting");
}

#[tokio::test]
async fn starting_write_launch_blocks_public_item_mutation() {
    let (db, _, preparation, launch) = reserved_write("starting-mutation").await;
    let applied = publish_write(&db, &preparation, launch).await;
    db.claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim write dispatch")
        .expect("pending write dispatch");

    let error = db
        .update_task_board_item(&applied.board_item_id, |item| {
            item.title = "Forbidden after claim".into();
            Ok(true)
        })
        .await
        .expect_err("starting write claim must fence public mutation");

    assert!(
        error
            .to_string()
            .contains("cannot change while its workflow side effect is claimed")
    );
}

async fn reserved_write(
    label: &str,
) -> (
    TestDb,
    String,
    ClaimedTaskBoardDispatchPreparation,
    TaskBoardWriteWorkflowLaunch,
) {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let item_id = format!("admission-write-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Implement approved plan".into(),
        "Focused tests pass".into(),
        APPROVED_AT.into(),
    );
    item.planning.summary = Some("# Plan\n\nImplement the requested change.".into());
    item.planning.approved_by = Some("lead".into());
    item.planning.approved_at = Some(APPROVED_AT.into());
    db.create_task_board_item(item).await.expect("create item");
    let plan = create_plan_for_existing(&db, &item_id).await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve write dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    let snapshot = db
        .task_board_item_snapshot(&item_id)
        .await
        .expect("source item snapshot");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    let reviewers = resolve_task_board_reviewers(
        &settings.settings.reviewers,
        TaskBoardWorkflowKind::DefaultTask,
        None,
    )
    .expect("resolved reviewers");
    let workflow_snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: None,
        item_revision: snapshot.item_revision,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        reviewer: reviewers.clone(),
        read_only_run_context: None,
        provider_revision: None,
    };
    let planning_result = build_planning_result(
        snapshot.item.planning.summary.as_deref().expect("plan"),
        [snapshot.item.body.clone()],
        &workflow_snapshot,
        &preparation.preparation.workflow_execution_id,
    )
    .expect("build planning result");
    let plan_approval = bind_plan_approval(
        &planning_result,
        &workflow_snapshot,
        &preparation.preparation.workflow_execution_id,
        "lead",
        APPROVED_AT,
    )
    .expect("bind plan approval");
    let launch = TaskBoardWriteWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: None,
        configuration_revision: workflow_snapshot.configuration_revision,
        policy_version: workflow_snapshot.policy_version,
        resolved_reviewers: reviewers,
        source_item_revision: snapshot.item_revision,
        prepared_item_revision: snapshot.item_revision,
        task_id: preparation.preparation.work_item_id.clone(),
        run_context: crate::task_board::TaskBoardReadOnlyRunContext {
            schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: preparation.preparation.session_id.clone(),
            title: snapshot.item.title.clone(),
            body: snapshot.item.body.clone(),
            tags: snapshot.item.tags.clone(),
            worktree: "/tmp/worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        base_head_revision: "head-base".into(),
        planning_result,
        plan_approval,
    };
    (db, intent, preparation, launch)
}

async fn publish_write(
    db: &AsyncDaemonDb,
    preparation: &ClaimedTaskBoardDispatchPreparation,
    launch: TaskBoardWriteWorkflowLaunch,
) -> DispatchAppliedTask {
    db.complete_task_board_dispatch_preparation_with_workflow(
        preparation,
        "branch",
        "/tmp/worktree",
        None,
        Some(Box::new(launch)),
    )
    .await
    .expect("publish prepared write launch")
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
        .expect("load intent status")
}
