use super::*;

#[test]
fn drop_task_async_actively_delivers_to_idle_tui_agent() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-active-drop-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = Arc::new(
                    crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                        .await
                        .expect("open async daemon db"),
                );
                let db_slot = Arc::new(OnceLock::new());
                let async_db_slot = Arc::new(OnceLock::new());
                async_db_slot
                    .set(Arc::clone(&async_db))
                    .expect("async db slot");
                let (sender, _) = broadcast::channel(8);
                let manager =
                    AgentTuiManagerHandle::new_with_async_db(sender, db_slot, async_db_slot, false);

                let session_id = "daemon-async-active-drop";
                let state = start_direct_session_async(
                    &async_db,
                    project,
                    session_id,
                    "async active drop",
                    "wake idle tui worker on task drop",
                    None,
                )
                .await;
                let leader_id = state.leader_id.clone().expect("leader id");
                let worker_session_id = "async-active-drop-worker";
                let signal_dir = runtime::runtime_for_name("codex")
                    .expect("codex runtime")
                    .signal_dir(project, worker_session_id);
                let script_path = write_idle_signal_script(
                    project,
                    &signal_dir,
                    worker_session_id,
                    session_id,
                    IdleSignalScriptBehavior::AckOnWake,
                );

                let snapshot = manager
                    .start(
                        session_id,
                        &AgentTuiStartRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec![],
                            name: Some("idle worker".into()),
                            prompt: None,
                            project_dir: Some(project.to_string_lossy().into()),
                            argv: vec!["sh".into(), script_path.to_string_lossy().into_owned()],
                            rows: 5,
                            cols: 40,
                            persona: None,
                            model: None,
                            effort: None,
                            allow_custom_model: false,
                        },
                    )
                    .expect("start agent tui");
                manager
                    .signal_ready(&snapshot.tui_id)
                    .expect("signal ready");

                let joined = join_session_direct_async(
                    session_id,
                    &crate::daemon::protocol::SessionJoinRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![
                            "agent-tui".into(),
                            format!("agent-tui:{}", snapshot.tui_id),
                        ],
                        name: Some("idle worker".into()),
                        project_dir: project.to_string_lossy().into(),
                        persona: None,
                    },
                    &async_db,
                )
                .await
                .expect("join session");
                let worker_id = joined
                    .agents
                    .values()
                    .find(|agent| agent.role == SessionRole::Worker)
                    .expect("worker agent")
                    .agent_id
                    .clone();

                let created = create_task_async(
                    session_id,
                    &TaskCreateRequest {
                        actor: leader_id.clone(),
                        title: "actively delivered task".into(),
                        context: Some("deliver immediately via async daemon path".into()),
                        severity: crate::session::types::TaskSeverity::Medium,
                        suggested_fix: None,
                    },
                    &async_db,
                )
                .await
                .expect("create task");
                let task_id = created.tasks[0].task_id.clone();

                let dropped = drop_task_async(
                    session_id,
                    &task_id,
                    &TaskDropRequest {
                        actor: leader_id,
                        target: crate::daemon::protocol::TaskDropTarget::Agent {
                            agent_id: worker_id.clone(),
                        },
                        queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                    },
                    &async_db,
                    Some(&manager),
                )
                .await
                .expect("drop task");

                let task = dropped
                    .tasks
                    .iter()
                    .find(|task| task.task_id == task_id)
                    .expect("dropped task");
                assert_eq!(task.status, crate::session::types::TaskStatus::InProgress);
                assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));

                let action_hint = format!("task:{task_id}");
                let signal = dropped
                    .signals
                    .iter()
                    .find(|signal| {
                        signal.agent_id == worker_id
                            && signal.signal.payload.action_hint.as_deref()
                                == Some(action_hint.as_str())
                    })
                    .expect("delivered signal");
                assert_eq!(signal.status, SessionSignalStatus::Delivered);
                assert_eq!(
                    signal.acknowledgment.as_ref().map(|ack| ack.result),
                    Some(AckResult::Accepted)
                );
            });
        });
    });
}
