use super::*;

#[tokio::test]
async fn failed_and_cancelled_openrouter_runs_retain_terminal_evidence() {
    for (label, status, detail, expected_status) in [
        (
            "or-failed",
            AgentTurnRunStatus::Failed,
            "provider rejected the turn",
            TaskBoardAiReviewReportStatus::Failed,
        ),
        (
            "or-cancelled",
            AgentTurnRunStatus::Cancelled,
            "operator cancelled the turn",
            TaskBoardAiReviewReportStatus::Cancelled,
        ),
    ] {
        let fixture = Box::pin(seed_execution_with_reviewer_runtime(label, "openrouter")).await;
        let db = AsyncDaemonDb::connect(&fixture.test.path)
            .await
            .expect("open coordinator database");
        let db = AsyncDaemonDbHandle(db);
        let store = AsyncDaemonDb::connect(&fixture.test.path)
            .await
            .expect("open runtime store");
        let store = AsyncDaemonDbHandle(store);
        let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);
        reconcile(&db, &runtime, NOW).await;
        reconcile(&db, &runtime, NOW).await;
        let run_id = load(&fixture, &db).await.attempts[0]
            .idempotency_key
            .clone();
        finish_run(
            &db,
            &run_id,
            status,
            Some("partial provider output"),
            Some(detail),
        )
        .await;

        reconcile(&db, &runtime, RETRY_AT).await;
        reconcile(&db, &runtime, RETRY_AT).await;

        let reports = db
            .task_board_ai_review_reports(&fixture.item_id)
            .await
            .expect("load retained reports");
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].status, expected_status);
        assert_eq!(
            reports[0].partial_output.as_deref(),
            Some("partial provider output")
        );
        assert_eq!(reports[0].terminal_reason.as_deref(), Some(detail));
        assert_eq!(runtime.start_count(), 1);
    }
}

#[tokio::test]
async fn terminal_openrouter_failure_resumes_once_after_runtime_restart() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-restart",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;
    let first_key = load(&fixture, &db).await.attempts[0]
        .idempotency_key
        .clone();
    assert_eq!(runtime.start_count(), 1);

    runtime.evict_agent_turn_on_next_load();
    reconcile(&db, &runtime, NOW).await;
    assert_eq!(
        db.reconcile_interrupted_agent_turn_runs()
            .await
            .expect("correlated run stays for harvesting"),
        0
    );
    assert_eq!(
        db.agent_turn_run(&first_key)
            .await
            .expect("load settled run")
            .expect("settled run")
            .status,
        AgentTurnRunStatus::Failed
    );

    let restarted_store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("reopen runtime store");
    let restarted_store = AsyncDaemonDbHandle(restarted_store);
    let restarted_runtime = FakeReadOnlyRuntime::new([]).with_durable_db(restarted_store);

    reconcile(&db, &restarted_runtime, NOW).await;
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(restarted_runtime.start_count(), 0);
    assert_eq!(
        load(&fixture, &db).await.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );

    for _ in 0..8 {
        if restarted_runtime.start_count() == 1 {
            break;
        }
        reconcile(&db, &restarted_runtime, RETRY_AT).await;
    }
    let execution = load(&fixture, &db).await;
    assert_eq!(execution.attempts.len(), 2);
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(restarted_runtime.start_count(), 1);
    let second_key = execution.attempts[1].idempotency_key.clone();
    assert_ne!(second_key, first_key);
    assert_eq!(execution.attempts[1].state, TaskBoardAttemptState::Running);
    assert_eq!(
        db.agent_turn_run(&second_key)
            .await
            .expect("load resumed run")
            .expect("resumed run")
            .status,
        AgentTurnRunStatus::Running
    );
    assert_eq!(
        db.agent_turn_run(&first_key)
            .await
            .expect("load original run")
            .expect("original run")
            .status,
        AgentTurnRunStatus::Failed
    );
}
