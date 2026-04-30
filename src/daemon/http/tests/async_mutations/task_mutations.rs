use super::*;

#[test]
fn post_task_create_uses_async_db_when_sync_db_is_unavailable() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("http-async-task-create"), || {
            let project_dir = sandbox.path().join("project");
            init_git_project(&project_dir);

            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = sandbox.path().join("daemon.sqlite");
                let state = test_http_state_with_empty_async_db(&db_path).await;
                let _ =
                    start_async_http_session(state.clone(), &project_dir, "http-async-task").await;

                let response = post_task_create(
                    axum::extract::Path("http-async-task".to_owned()),
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
        });
    });
}

#[test]
fn post_task_create_allows_observer_in_leaderless_degraded_session() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("http-async-degraded-leader")),
                ("CODEX_SESSION_ID", Some("http-async-degraded-observer")),
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
                        "http-async-degraded-task",
                    )
                    .await;

                    let response = post_session_join(
                        axum::extract::Path("http-async-degraded-task".to_owned()),
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
                        .resolve_session("http-async-degraded-task")
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
                        axum::extract::Path("http-async-degraded-task".to_owned()),
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
                ("CLAUDE_SESSION_ID", Some("http-async-task-assign-leader")),
                ("CODEX_SESSION_ID", Some("http-async-task-assign-worker")),
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
                        "http-async-task-assign",
                    )
                    .await;
                    let _ = post_session_join(
                        axum::extract::Path("http-async-task-assign".to_owned()),
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
                        axum::extract::Path("http-async-task-assign".to_owned()),
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
                        .resolve_session("http-async-task-assign")
                        .await
                        .expect("resolve session")
                        .expect("session present");
                    let worker_id = resolved
                        .state
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .to_string();

                    let response = post_task_assign(
                        axum::extract::Path(("http-async-task-assign".to_owned(), task_id)),
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
            Some("http-async-task-checkpoint"),
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
                        "http-async-task-checkpoint",
                    )
                    .await;
                    let created = post_task_create(
                        axum::extract::Path("http-async-task-checkpoint".to_owned()),
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
                            "http-async-task-checkpoint".to_owned(),
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
