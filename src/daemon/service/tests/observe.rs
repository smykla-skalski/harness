use super::*;

#[test]
fn observe_session_with_actor_creates_tasks() {
    install_test_observe_runtime(Duration::from_secs(60));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    with_temp_project(|project| {
        let state = session_service::start_session(
            "observe test",
            "",
            project,
            Some("claude"),
            Some("daemon-observe"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");

        temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            session_service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join codex worker");
        });

        append_project_ledger_entry(project);
        write_agent_log(
            project,
            HookAgent::Codex,
            "worker-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let detail = runtime
            .block_on(async {
                observe_session(
                    &state.session_id,
                    Some(&ObserveSessionRequest {
                        actor: Some(leader_id),
                    }),
                    None,
                )
            })
            .expect("observe session");

        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(
            detail.tasks[0].source,
            crate::session::types::TaskSource::Observe
        );
    });
}

#[test]
fn observe_session_restarts_running_loop_when_actor_changes() {
    install_test_observe_runtime(Duration::from_secs(60));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    with_temp_project(|project| {
        let state = session_service::start_session(
            "observe restart test",
            "",
            project,
            Some("claude"),
            Some("daemon-observe"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");

        let joined_state =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                session_service::join_session(
                    &state.session_id,
                    SessionRole::Observer,
                    "codex",
                    &[],
                    Some("observer"),
                    project,
                    None,
                )
            })
            .expect("join observer");
        let observer_id = joined_state
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Observer)
            .map(|agent| agent.agent_id.clone())
            .expect("observer id");

        append_project_ledger_entry(project);
        write_agent_log(
            project,
            HookAgent::Codex,
            "observer-session",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        runtime
            .block_on(async {
                observe_session(
                    &state.session_id,
                    Some(&ObserveSessionRequest {
                        actor: Some(leader_id),
                    }),
                    None,
                )
            })
            .expect("observe session with leader");
        runtime
            .block_on(async {
                observe_session(
                    &state.session_id,
                    Some(&ObserveSessionRequest {
                        actor: Some(observer_id.clone()),
                    }),
                    None,
                )
            })
            .expect("observe session with observer");

        let observe_runtime = OBSERVE_RUNTIME.get().expect("observe runtime");
        let running_sessions = observe_runtime
            .running_sessions
            .lock()
            .expect("running sessions lock");
        let registration = running_sessions
            .get(&state.session_id)
            .expect("running session registration");

        assert_eq!(
            registration.request.actor_id.as_deref(),
            Some(observer_id.as_str())
        );
        assert_eq!(registration.generation, 2);
    });
}

#[test]
fn observe_session_async_creates_tasks_without_sync_db() {
    install_test_observe_runtime(Duration::from_secs(60));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    with_temp_project(|project| {
        let state = session_service::start_session(
            "observe async test",
            "",
            project,
            Some("claude"),
            Some("observe-async-leader"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");
        temp_env::with_vars([("CODEX_SESSION_ID", Some("observe-async-worker"))], || {
            session_service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join codex worker");
        });
        append_project_ledger_entry(project);
        write_agent_log(
            project,
            HookAgent::Codex,
            "observe-async-worker",
            "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        );

        let detail = runtime.block_on(async {
            let async_db = setup_async_db_with_session(project, &state.session_id).await;
            install_test_observe_async_db(async_db.clone());
            observe_session_async(
                &state.session_id,
                Some(&ObserveSessionRequest {
                    actor: Some(leader_id),
                }),
                async_db.as_ref(),
            )
            .await
            .expect("observe session async")
        });

        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(
            detail.tasks[0].source,
            crate::session::types::TaskSource::Observe
        );
    });
}

#[test]
fn run_daemon_observe_task_does_not_consume_blocking_pool_threads() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .expect("runtime");
    runtime.block_on(async {
        let observe_task = tokio::spawn(async {
            run_daemon_observe_task_with(
                "session-a".into(),
                PathBuf::from("/tmp/project"),
                Duration::from_secs(1),
                None,
                |_session_id, _project_dir, _poll_interval, _actor_id| async {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    Ok(0)
                },
            )
            .await
        });

        let blocking_result =
            tokio::time::timeout(Duration::from_millis(50), tokio::task::spawn_blocking(|| 7))
                .await
                .expect("observe loop should leave the blocking pool available")
                .expect("blocking task join");

        assert_eq!(blocking_result, 7);
        let observe_result = observe_task.await.expect("observe join");
        assert_eq!(observe_result.expect("observe result"), 0);
    });
}
