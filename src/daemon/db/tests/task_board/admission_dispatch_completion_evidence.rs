use super::*;

#[tokio::test]
async fn read_only_dispatch_atomically_starts_workflow_with_exact_completion_evidence() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let mut item = TaskBoardItem::new(
        "admission-read-only".into(),
        "Review exact head".into(),
        "Review without workspace writes".into(),
        "2026-07-17T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    db.create_task_board_item(item).await.expect("create item");
    let mut launch = read_only_launch(&db).await;
    let plan = create_plan_for_existing(&db, "admission-read-only").await;
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
        .task_board_item_snapshot("admission-read-only")
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
        )
        .await
        .expect("complete preparation");
    let published_launch = applied
        .read_only_workflow
        .as_ref()
        .expect("published read-only launch");
    let source_item_revision = published_launch.source_item_revision;
    assert_eq!(
        published_launch.prepared_item_revision,
        source_item_revision + 1
    );
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("execution id");
    let claim = db
        .claim_task_board_dispatch("admission-read-only")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let owner = workflow_owner(&execution_id);

    db.complete_task_board_dispatch(&intent, &claim.claim_token, &owner)
        .await
        .expect("commit read-only dispatch");

    let execution = db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load execution")
        .expect("durable execution");
    assert_initial_report_deadline(&execution.attempts[0]);
    let item = db
        .task_board_item_snapshot("admission-read-only")
        .await
        .expect("load item snapshot");
    assert_eq!(item.item_revision, source_item_revision + 2);
    assert_eq!(execution.snapshot.item_revision, item.item_revision);
    assert_eq!(
        execution.transition.phase,
        Some(crate::task_board::TaskBoardExecutionPhase::Review)
    );
    assert_eq!(
        execution.transition.execution_state,
        crate::task_board::TaskBoardExecutionState::Running
    );
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(
        execution.attempts[0].action_key,
        "review:default-code-reviewer"
    );
    let side_effect_worker_id = format!("codex-{intent}");
    assert_eq!(execution.attempts[0].idempotency_key, side_effect_worker_id);
    assert_eq!(
        execution.ownership.resources.get("admission_owner"),
        Some(&owner)
    );
    assert_completion_evidence(&db, &intent, &execution_id, &owner, &side_effect_worker_id).await;
}

async fn read_only_launch(db: &AsyncDaemonDb) -> TaskBoardReadOnlyWorkflowLaunch {
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version.clone(),
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("resolved reviewers"),
        source_item_revision: 1,
        prepared_item_revision: 1,
        run_context: crate::task_board::TaskBoardReadOnlyRunContext {
            schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: "session-existing".into(),
            title: "Review exact head".into(),
            body: "Review without workspace writes".into(),
            tags: Vec::new(),
            worktree: "/tmp/worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: "head-frozen".into(),
    }
}

fn assert_initial_report_deadline(attempt: &crate::task_board::TaskBoardExecutionAttemptRecord) {
    let deadline = chrono::DateTime::parse_from_rfc3339(
        attempt
            .available_at
            .as_deref()
            .expect("initial report claim deadline"),
    )
    .expect("parse initial report claim deadline");
    let started = chrono::DateTime::parse_from_rfc3339(&attempt.started_at)
        .expect("parse initial report start");
    assert_eq!(
        deadline.signed_duration_since(started),
        chrono::Duration::seconds(crate::task_board::TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS)
    );
}

async fn assert_completion_evidence(
    db: &AsyncDaemonDb,
    intent_id: &str,
    execution_id: &str,
    owner: &str,
    side_effect_worker_id: &str,
) {
    assert!(
        completion_matches(
            db,
            intent_id,
            execution_id,
            owner,
            owner,
            side_effect_worker_id,
        )
        .await
    );
    for (ledger_owner, workflow_owner, worker_id) in [
        ("wrong-ledger-worker", owner, side_effect_worker_id),
        (owner, "wrong-workflow-owner", side_effect_worker_id),
        (owner, owner, "wrong-side-effect-worker"),
    ] {
        assert!(
            !completion_matches(
                db,
                intent_id,
                execution_id,
                ledger_owner,
                workflow_owner,
                worker_id,
            )
            .await
        );
    }
    sqlx::query(
        "DELETE FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = 'concurrency'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("remove required completion evidence");
    assert!(
        !completion_matches(
            db,
            intent_id,
            execution_id,
            owner,
            owner,
            side_effect_worker_id,
        )
        .await
    );
}

async fn completion_matches(
    db: &AsyncDaemonDb,
    intent_id: &str,
    execution_id: &str,
    managed_worker_id: &str,
    admission_owner_id: &str,
    side_effect_worker_id: &str,
) -> bool {
    db.task_board_dispatch_completion_matches(
        intent_id,
        execution_id,
        managed_worker_id,
        admission_owner_id,
        side_effect_worker_id,
        true,
    )
    .await
    .expect("check exact dispatch completion")
}
