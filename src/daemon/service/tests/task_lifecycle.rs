use super::*;

#[test]
fn drop_queue_policy_and_status_async_refresh_session_state() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("async-task-lifecycle-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let db_path = project
                        .parent()
                        .expect("project parent")
                        .join("daemon.sqlite");
                    let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                        .await
                        .expect("open async daemon db");

                    let state = start_direct_session_async(
                        &async_db,
                        project,
                        "daemon-async-task-lifecycle",
                        "async task lifecycle",
                        "async task lifecycle flow",
                        None,
                    )
                    .await;
                    let leader_id = state.leader_id.clone().expect("leader id");
                    let joined = join_session_direct_async(
                        "daemon-async-task-lifecycle",
                        &crate::daemon::protocol::SessionJoinRequest {
                            runtime: "codex".into(),
                            role: SessionRole::Worker,
                            fallback_role: None,
                            capabilities: vec![],
                            name: None,
                            project_dir: project.to_string_lossy().into(),
                            persona: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("join session");
                    let worker_id = joined
                        .agents
                        .keys()
                        .find(|agent_id| agent_id.starts_with("codex-"))
                        .expect("worker id")
                        .to_string();

                    let first = create_task_async(
                        "daemon-async-task-lifecycle",
                        &TaskCreateRequest {
                            actor: leader_id.clone(),
                            title: "first async task".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::High,
                            suggested_fix: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("create first task");
                    let first_task = first.tasks[0].task_id.clone();
                    let second = create_task_async(
                        "daemon-async-task-lifecycle",
                        &TaskCreateRequest {
                            actor: leader_id.clone(),
                            title: "second async task".into(),
                            context: None,
                            severity: crate::session::types::TaskSeverity::Medium,
                            suggested_fix: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("create second task");
                    let second_task = second
                        .tasks
                        .iter()
                        .find(|task| task.title == "second async task")
                        .expect("second task")
                        .task_id
                        .clone();

                    let dropped = drop_task_async(
                        "daemon-async-task-lifecycle",
                        &first_task,
                        &crate::daemon::protocol::TaskDropRequest {
                            actor: leader_id.clone(),
                            target: crate::daemon::protocol::TaskDropTarget::Agent {
                                agent_id: worker_id.clone(),
                            },
                            queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                        },
                        &async_db,
                    )
                    .await
                    .expect("drop first task");
                    let first_detail = dropped
                        .tasks
                        .iter()
                        .find(|task| task.task_id == first_task)
                        .expect("first task detail");
                    assert_eq!(
                        first_detail.assigned_to.as_deref(),
                        Some(worker_id.as_str())
                    );

                    let _ = drop_task_async(
                        "daemon-async-task-lifecycle",
                        &second_task,
                        &crate::daemon::protocol::TaskDropRequest {
                            actor: leader_id.clone(),
                            target: crate::daemon::protocol::TaskDropTarget::Agent {
                                agent_id: worker_id.clone(),
                            },
                            queue_policy: crate::session::types::TaskQueuePolicy::Locked,
                        },
                        &async_db,
                    )
                    .await
                    .expect("queue second task");

                    let reprioritized = update_task_queue_policy_async(
                        "daemon-async-task-lifecycle",
                        &second_task,
                        &crate::daemon::protocol::TaskQueuePolicyRequest {
                            actor: leader_id.clone(),
                            queue_policy: crate::session::types::TaskQueuePolicy::ReassignWhenFree,
                        },
                        &async_db,
                    )
                    .await
                    .expect("update queue policy");
                    let second_detail = reprioritized
                        .tasks
                        .iter()
                        .find(|task| task.task_id == second_task)
                        .expect("second task detail");
                    assert_eq!(
                        second_detail.queue_policy,
                        crate::session::types::TaskQueuePolicy::ReassignWhenFree
                    );

                    let completed = update_task_async(
                        "daemon-async-task-lifecycle",
                        &first_task,
                        &crate::daemon::protocol::TaskUpdateRequest {
                            actor: leader_id,
                            status: crate::session::types::TaskStatus::Done,
                            note: Some("completed asynchronously".into()),
                        },
                        &async_db,
                    )
                    .await
                    .expect("complete first task");
                    let second_detail = completed
                        .tasks
                        .iter()
                        .find(|task| task.task_id == second_task)
                        .expect("second task detail");
                    assert_eq!(
                        second_detail.status,
                        crate::session::types::TaskStatus::Open
                    );
                    let signals = async_db
                        .load_signals("daemon-async-task-lifecycle")
                        .await
                        .expect("load signals");
                    assert!(
                        signals.iter().any(|signal| signal.agent_id == worker_id),
                        "task lifecycle should refresh indexed signals for the worker"
                    );
                });
            },
        );
    });
}
