use super::*;

#[test]
fn post_task_create_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("aa60a455-cee0-57b0-b058-7a950b5dd40b-create"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "aa60a455-cee0-57b0-b058-7a950b5dd40b",
                    )
                    .await;

                    let response = post_task_create(
                        axum::extract::Path("aa60a455-cee0-57b0-b058-7a950b5dd40b".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: "spoofed".into(),
                            title: "async http task".into(),
                            context: Some("create via async route".into()),
                            severity: crate::session::types::TaskSeverity::High,
                            suggested_fix: Some("prefer sqlx pool".into()),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(body["tasks"][0]["title"].as_str(), Some("async http task"));
                });
            },
        );
    });
}

#[test]
fn post_task_create_allows_observer_in_leaderless_degraded_session() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("28255b9e-3e0d-5646-b398-3b0e7e5a59ef"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("7f6fe873-44d0-5f9d-8db6-afbafa1dba3f"),
                ),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "8e902843-ef09-52ef-902d-44e46e385237",
                    )
                    .await;

                    let response = post_session_join(
                        axum::extract::Path("8e902843-ef09-52ef-902d-44e46e385237".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Observer,
                            fallback_role: None,
                            capabilities: vec!["triage".into()],
                            name: Some("Async Observer".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;
                    let (status, _) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);

                    let async_db = state.async_db.get().expect("async db");
                    let mut resolved = async_db
                        .resolve_session("8e902843-ef09-52ef-902d-44e46e385237")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    let observer_id = resolved
                        .state
                        .agents
                        .values()
                        .find(|agent| agent.role == SessionRole::Observer)
                        .expect("observer")
                        .agent_id
                        .clone();
                    let previous_leader = resolved.state.leader_id.take().expect("leader");
                    resolved.state.status =
                        crate::session::types::SessionStatus::LeaderlessDegraded;
                    let leader = resolved
                        .state
                        .agents
                        .get_mut(&previous_leader)
                        .expect("leader registration");
                    leader.status = crate::session::types::AgentStatus::disconnected_unknown();
                    async_db
                        .save_session_state(&resolved.project.project_id, &resolved.state)
                        .await
                        .expect("persist degraded session");

                    let response = post_task_create(
                        axum::extract::Path("8e902843-ef09-52ef-902d-44e46e385237".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: observer_id,
                            title: "degraded async http task".into(),
                            context: Some("observer can still record findings".into()),
                            severity: crate::session::types::TaskSeverity::High,
                            suggested_fix: Some("preserve degraded triage".into()),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["tasks"][0]["title"].as_str(),
                        Some("degraded async http task")
                    );
                });
            },
        );
    });
}

#[test]
fn post_task_assign_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (
                    "CLAUDE_SESSION_ID",
                    Some("0dfc1b61-8f17-56d6-b50c-3e7beb1adc50-leader"),
                ),
                (
                    "CODEX_SESSION_ID",
                    Some("0dfc1b61-8f17-56d6-b50c-3e7beb1adc50-worker"),
                ),
            ],
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "0dfc1b61-8f17-56d6-b50c-3e7beb1adc50",
                    )
                    .await;
                    let _ = post_session_join(
                        axum::extract::Path("0dfc1b61-8f17-56d6-b50c-3e7beb1adc50".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec!["general".into()],
                            name: Some("Async Task Worker".into()),
                            project_dir: project_dir.to_string_lossy().into_owned(),
                            persona: None,
                        }),
                    )
                    .await;
                    let created = post_task_create(
                        axum::extract::Path("0dfc1b61-8f17-56d6-b50c-3e7beb1adc50".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: "spoofed".into(),
                            title: "assign me".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Medium,
                            suggested_fix: None,
                        }),
                    )
                    .await;
                    let (_, created_body) = response_json(created).await;
                    let task_id = created_body["tasks"][0]["task_id"]
                        .as_str()
                        .expect("task id")
                        .to_string();

                    let async_db = state.async_db.get().expect("async db");
                    let resolved = async_db
                        .resolve_session("0dfc1b61-8f17-56d6-b50c-3e7beb1adc50")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    let worker_id = resolved
                        .state
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .clone();

                    let response = post_task_assign(
                        axum::extract::Path((
                            "0dfc1b61-8f17-56d6-b50c-3e7beb1adc50".to_owned(),
                            task_id,
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskAssignRequest {
                            actor: "spoofed".into(),
                            agent_id: worker_id.clone(),
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["tasks"][0]["assigned_to"].as_str(),
                        Some(worker_id.as_str())
                    );
                });
            },
        );
    });
}

#[test]
fn post_task_checkpoint_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(
            "CLAUDE_SESSION_ID",
            Some("ecc5a03b-3221-5679-9abe-bc2b49efab36"),
            || {
                let project_dir = sandbox.path().join("project");
                init_git_project(&project_dir);

                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = sandbox.path().join("daemon.sqlite");
                    let state = test_http_state_with_empty_async_db(&db_path).await;
                    let _ = start_async_http_session(
                        state.clone(),
                        &project_dir,
                        "ecc5a03b-3221-5679-9abe-bc2b49efab36",
                    )
                    .await;
                    let created = post_task_create(
                        axum::extract::Path("ecc5a03b-3221-5679-9abe-bc2b49efab36".to_owned()),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCreateRequest {
                            actor: "spoofed".into(),
                            title: "checkpoint me".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Low,
                            suggested_fix: None,
                        }),
                    )
                    .await;
                    let (_, created_body) = response_json(created).await;
                    let task_id = created_body["tasks"][0]["task_id"]
                        .as_str()
                        .expect("task id")
                        .to_string();

                    let response = post_task_checkpoint(
                        axum::extract::Path((
                            "ecc5a03b-3221-5679-9abe-bc2b49efab36".to_owned(),
                            task_id.clone(),
                        )),
                        auth_headers(),
                        State(state.clone()),
                        Json(TaskCheckpointRequest {
                            actor: "spoofed".into(),
                            summary: "Halfway there".into(),
                            progress: 50,
                        }),
                    )
                    .await;

                    let (status, body) = response_json(response).await;
                    assert_eq!(status, StatusCode::OK);
                    assert_eq!(
                        body["tasks"][0]["checkpoint_summary"]["summary"].as_str(),
                        Some("Halfway there")
                    );
                });
            },
        );
    });
}
