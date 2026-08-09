use super::*;

#[test]
fn workspace_owned_openrouter_start_binds_the_same_sessionless_owner() {
    run_deep_async(workspace_owned_openrouter_start_binds_owner_body);
}

async fn workspace_owned_openrouter_start_binds_owner_body() {
    let (fixture, before) = Box::pin(live_claimed_executor_for_owner("openrouter", true)).await;
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("start workspace-owned OpenRouter worker");
    let copy = fixture
        .db
        .load_agent_working_copy(&identity.working_copy_id)
        .await
        .expect("load OpenRouter working copy")
        .expect("OpenRouter working copy");
    let run = fixture
        .db
        .agent_turn_run(&identity.run_id)
        .await
        .expect("load workspace-owned OpenRouter run")
        .expect("workspace-owned OpenRouter run");
    assert_eq!(run.session_id.as_deref(), Some(copy.workspace_id.as_str()));
    let members = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM agent_workspace_members WHERE workspace_id = ?1",
    )
    .bind(&copy.workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("count OpenRouter workspace members");
    assert_eq!(members, 1);
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("reconnect probes the authoritative OpenRouter worker");
    assert_eq!(scope.start_count().await, 1);
    assert_eq!(executor_session_count(&fixture.db).await, 0);
}

#[test]
fn openrouter_start_is_durable_and_restart_settles_once_without_codex_run() {
    run_deep_async(openrouter_start_is_durable_and_restart_settles_once_body);
}

async fn openrouter_start_is_durable_and_restart_settles_once_body() {
    let (fixture, before) = Box::pin(live_claimed_executor_for("openrouter")).await;
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("start OpenRouter through the remote runtime seam");
    let run = fixture
        .db
        .agent_turn_run(&identity.run_id)
        .await
        .expect("load OpenRouter run")
        .expect("durable OpenRouter run");
    assert_eq!(run.requested_runtime, "openrouter");
    assert_eq!(run.actual_runtime.as_deref(), Some("openrouter"));
    assert!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("check Codex store")
            .is_none()
    );
    assert_eq!(scope.calls().await.len(), 1);

    assert_eq!(
        fixture
            .db
            .reconcile_interrupted_agent_turn_runs()
            .await
            .expect("preserve correlated OpenRouter run"),
        0
    );
    drop(scope);
    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("settle the turn evicted from the restarted runtime");
    assert_eq!(
        load_assignment(&fixture.db, &before.assignment_id)
            .await
            .state,
        TaskBoardRemoteAssignmentState::Failed
    );
}
