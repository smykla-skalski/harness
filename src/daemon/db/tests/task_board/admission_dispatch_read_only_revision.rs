use super::*;
use crate::daemon::db::ClaimedTaskBoardDispatchPreparation;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{
    DispatchAppliedTask, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardLaunchCapability,
    TaskBoardReadOnlyRunContext,
};

#[tokio::test]
async fn read_only_launch_rejects_item_revision_aba_before_publication() {
    let (db, intent, preparation, launch) = reserved_read_only("revision-aba-publish", false).await;
    mutate_title_round_trip(&db, &preparation.preparation.board_item_id).await;

    let error = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
        )
        .await
        .expect_err("revision ABA must prevent preparation publication");

    assert!(error.to_string().contains("revision changed"));
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(codex_run_count(&db).await, 0);
    assert_eq!(intent_status(&db, &intent).await, "preparing_claimed");
}

#[tokio::test]
async fn read_only_publication_rebuilds_context_from_transaction_owned_item() {
    let (db, _, preparation, mut launch) =
        reserved_read_only("transaction-owned-context", false).await;
    launch.run_context.title = "forged title".into();
    launch.run_context.body = "forged body".into();
    launch.run_context.tags = vec!["forged".into()];
    launch.run_context.session_id = "forged-session".into();
    launch.run_context.worktree = "/tmp/forged".into();

    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
        )
        .await
        .expect("publish authoritative read-only context");
    let launch = applied
        .read_only_workflow
        .as_ref()
        .expect("read-only launch");
    let context = &launch.run_context;
    assert_eq!(context.title, "Review exact head");
    assert_eq!(context.body, "Review without workspace writes");
    assert!(context.tags.is_empty());
    assert_eq!(context.session_id, preparation.preparation.session_id);
    assert_eq!(context.worktree, "/tmp/worktree");
    let claimed = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim persisted read-only dispatch")
        .expect("pending read-only dispatch");
    let persisted_launch = claimed
        .applied
        .read_only_workflow
        .as_ref()
        .expect("persisted read-only launch");
    let persisted = &persisted_launch.run_context;
    assert_eq!(persisted, context);
}

#[tokio::test]
async fn read_only_publication_rejects_forged_workflow_identity() {
    let (db, _, preparation, mut launch) =
        reserved_read_only("forged-workflow-identity", false).await;
    launch.workflow_kind = TaskBoardWorkflowKind::PrReview;

    let error = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
        )
        .await
        .expect_err("publication must reject a mismatched read-only workflow kind");

    assert!(error.to_string().contains("workflow identity changed"));
}

#[tokio::test]
async fn read_only_reservation_rejects_item_revision_aba_before_preparation_claim() {
    let (db, intent, item_id, _) = reserved_read_only_unclaimed("revision-aba-claim", false).await;
    mutate_title_round_trip(&db, &item_id).await;

    let error = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect_err("revision ABA must prevent preparation claim");

    assert!(
        error
            .to_string()
            .contains("changed before preparation claim")
    );
    assert_eq!(intent_status(&db, &intent).await, "failed");
    assert_eq!(active_admission_count(&db, &intent).await, 0);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(codex_run_count(&db).await, 0);
}

#[tokio::test]
async fn legacy_read_only_preparation_fails_closed_while_write_preparation_claims() {
    let (db, read_only_intent, _, _) = reserved_read_only_unclaimed("legacy-revision", false).await;
    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET payload_json = json_remove(payload_json, '$.source_item_revision')
         WHERE intent_id = ?1",
    )
    .bind(&read_only_intent)
    .execute(db.pool())
    .await
    .expect("remove legacy revision fence");

    let error = db
        .claim_task_board_dispatch_preparation(&read_only_intent)
        .await
        .expect_err("legacy read-only preparation must fail closed");
    assert!(error.to_string().contains("no frozen item revision"));
    assert_eq!(intent_status(&db, &read_only_intent).await, "failed");
    assert_eq!(active_admission_count(&db, &read_only_intent).await, 0);

    let plan = create_plan(&db, "legacy-write-preparation", AgentMode::Headless).await;
    let write_intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve legacy write dispatch"),
    );
    assert!(
        db.claim_task_board_dispatch_preparation(&write_intent)
            .await
            .expect("claim legacy write preparation")
            .is_some()
    );
}

#[tokio::test]
async fn read_only_launch_rejects_item_revision_aba_before_pending_claim() {
    let (db, intent, applied) = publish_read_only("revision-aba-pending", false).await;
    mutate_title_round_trip(&db, &applied.board_item_id).await;

    let error = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect_err("revision ABA must prevent pending worker claim");

    assert!(error.to_string().contains("changed before worker claim"));
    assert_eq!(intent_status(&db, &intent).await, "failed");
    let item = db
        .task_board_item(&applied.board_item_id)
        .await
        .expect("rolled-back item");
    assert_eq!(item.status, crate::task_board::TaskBoardStatus::Todo);
    assert_eq!(
        item.workflow.status,
        crate::task_board::TaskBoardWorkflowStatus::Failed
    );
    assert_eq!(item.workflow.current_step_id.as_deref(), Some("admission"));
    assert_eq!(item.session_id, None);
    assert_eq!(item.work_item_id, None);
    let active_admission_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state IN ('reserved', 'committed')",
    )
    .bind(&intent)
    .fetch_one(db.pool())
    .await
    .expect("count active admission rows");
    assert_eq!(active_admission_rows, 0);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(codex_run_count(&db).await, 0);
}

#[tokio::test]
async fn starting_read_only_launch_blocks_public_item_mutation() {
    let (db, intent, applied) = publish_read_only("starting-mutation-gate", false).await;
    let before = db
        .task_board_item_snapshot(&applied.board_item_id)
        .await
        .expect("item before claim");
    db.claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim read-only dispatch")
        .expect("pending read-only dispatch");

    let error = db
        .update_task_board_item(&applied.board_item_id, |item| {
            item.title = "Forbidden after claim".into();
            Ok(true)
        })
        .await
        .expect_err("starting read-only claim must fence public mutation");
    assert!(
        error
            .to_string()
            .contains("cannot change while its read-only side effect is claimed")
    );
    let after = db
        .task_board_item_snapshot(&applied.board_item_id)
        .await
        .expect("item after rejected mutation");
    assert_eq!(after.item_revision, before.item_revision);
    assert_eq!(after.item.title, before.item.title);
    assert_eq!(intent_status(&db, &intent).await, "starting");
}

#[tokio::test]
async fn read_only_completion_rechecks_revision_after_start_authorization() {
    let (db, intent, applied) = publish_read_only("revision-aba-completion", false).await;
    let launch = applied
        .read_only_workflow
        .as_ref()
        .expect("read-only launch");
    let claim = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim read-only dispatch")
        .expect("pending read-only dispatch");
    db.validate_task_board_dispatch_admission_start(
        &intent,
        &claim.claim_token,
        Some(TaskBoardLaunchCapability::ReportReadOnly),
        Some((launch.prepared_item_revision, launch.configuration_revision)),
    )
    .await
    .expect("authorize stable read-only start");
    sqlx::query("UPDATE task_board_items SET revision = revision + 2 WHERE item_id = ?1")
        .bind(&applied.board_item_id)
        .execute(db.pool())
        .await
        .expect("simulate out-of-band ABA after authorization");

    let error = db
        .complete_task_board_dispatch(
            &intent,
            &claim.claim_token,
            &workflow_owner(
                applied
                    .item
                    .workflow
                    .execution_id
                    .as_deref()
                    .expect("execution id"),
            ),
        )
        .await
        .expect_err("revision ABA must prevent durable execution insertion");

    assert!(
        error
            .to_string()
            .contains("item revision changed before worker start")
    );
    let snapshot = db
        .task_board_item_snapshot(&applied.board_item_id)
        .await
        .expect("item after rolled-back completion");
    assert_eq!(snapshot.item_revision, launch.prepared_item_revision + 2);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(codex_run_count(&db).await, 0);
    assert_eq!(intent_status(&db, &intent).await, "starting");
}

#[tokio::test]
async fn held_read_only_launch_advances_revision_fence_through_completion() {
    let (db, intent, applied) = publish_read_only("held-revision-offsets", true).await;
    let published = applied
        .read_only_workflow
        .as_ref()
        .expect("published read-only launch");
    assert_eq!(
        published.prepared_item_revision,
        published.source_item_revision + 1
    );
    let source_item_revision = published.source_item_revision;
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("execution id");

    let claim = db
        .claim_held_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim held read-only dispatch");
    let claimed = claim
        .applied
        .read_only_workflow
        .as_ref()
        .expect("claimed read-only launch");
    assert_eq!(claimed.source_item_revision, source_item_revision);
    assert_eq!(claimed.prepared_item_revision, source_item_revision + 2);
    db.complete_task_board_dispatch(&intent, &claim.claim_token, &workflow_owner(&execution_id))
        .await
        .expect("complete held read-only dispatch");

    let item = db
        .task_board_item_snapshot(&applied.board_item_id)
        .await
        .expect("completed held item");
    let execution = db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load held execution")
        .expect("durable held execution");
    assert_eq!(item.item_revision, source_item_revision + 3);
    assert_eq!(execution.snapshot.item_revision, source_item_revision + 3);
}

#[tokio::test]
async fn held_read_only_launch_rejects_item_revision_aba_before_claim() {
    let (db, intent, applied) = publish_read_only("held-revision-aba", true).await;
    mutate_title_round_trip(&db, &applied.board_item_id).await;

    let error = db
        .claim_held_task_board_dispatch(&applied.board_item_id)
        .await
        .expect_err("revision ABA must prevent held worker claim");

    assert!(
        error
            .to_string()
            .contains("changed before held worker claim")
    );
    assert_eq!(intent_status(&db, &intent).await, "held");
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(codex_run_count(&db).await, 0);
}

async fn reserved_read_only(
    label: &str,
    hold_worker: bool,
) -> (
    TestDb,
    String,
    ClaimedTaskBoardDispatchPreparation,
    TaskBoardReadOnlyWorkflowLaunch,
) {
    let (db, intent, item_id, launch) = reserved_read_only_unclaimed(label, hold_worker).await;
    let claimed = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    assert_eq!(claimed.preparation.board_item_id, item_id);
    (db, intent, claimed, launch)
}

async fn reserved_read_only_unclaimed(
    label: &str,
    hold_worker: bool,
) -> (TestDb, String, String, TaskBoardReadOnlyWorkflowLaunch) {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    if hold_worker {
        let mut workspace = PolicyCanvasWorkspace::seeded();
        workspace.spawn_requires_live_policy = false;
        db.replace_policy_workspace(&workspace)
            .await
            .expect("allow held delivery without a live policy");
    }
    let item_id = format!("admission-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Review exact head".into(),
        "Review without workspace writes".into(),
        "2026-07-17T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    db.create_task_board_item(item).await.expect("create item");
    let plan = create_plan_for_existing(&db, &item_id).await;
    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), hold_worker)
        .await
        .expect("reserve dispatch");
    let (intent, preparation) = match reserved {
        crate::daemon::db::ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        } => (intent_id, preparation),
        other => panic!("unexpected reservation: {other:?}"),
    };
    let snapshot = db
        .task_board_item_snapshot(&item_id)
        .await
        .expect("source item snapshot");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    let launch = TaskBoardReadOnlyWorkflowLaunch {
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
            session_id: preparation.session_id.clone(),
            title: snapshot.item.title,
            body: snapshot.item.body,
            tags: snapshot.item.tags,
            worktree: "/tmp/worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: "head-frozen".into(),
    };
    (db, intent, item_id, launch)
}

async fn publish_read_only(
    label: &str,
    hold_worker: bool,
) -> (TestDb, String, DispatchAppliedTask) {
    let (db, intent, preparation, launch) = reserved_read_only(label, hold_worker).await;
    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
        )
        .await
        .expect("publish prepared read-only launch");
    (db, intent, applied)
}

async fn mutate_title_round_trip(db: &AsyncDaemonDb, item_id: &str) {
    for title in ["Transient edit", "Review exact head"] {
        db.update_task_board_item(item_id, |item| {
            item.title = title.into();
            Ok(true)
        })
        .await
        .expect("mutate item title")
        .expect("item title mutation");
    }
}

async fn workflow_execution_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_workflow_executions")
        .fetch_one(db.pool())
        .await
        .expect("count workflow executions")
}

async fn codex_run_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count Codex runs")
}

async fn intent_status(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load intent status")
}

async fn active_admission_count(db: &AsyncDaemonDb, intent_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state IN ('reserved', 'committed')",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("count active dispatch admission rows")
}
