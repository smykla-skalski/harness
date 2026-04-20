use super::*;

#[test]
fn create_task_uses_suggested_fix_from_request() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon task request",
            "",
            project,
            Some("claude"),
            Some("daemon-task"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");

        append_project_ledger_entry(project);
        let detail = create_task(
            &state.session_id,
            &TaskCreateRequest {
                actor: leader_id,
                title: "Patch the watch mapper".into(),
                context: Some("watch loop uses the wrong session key".into()),
                severity: crate::session::types::TaskSeverity::High,
                suggested_fix: Some("resolve runtime-session ids through daemon index".into()),
            },
            None,
        )
        .expect("create task");

        assert_eq!(detail.tasks.len(), 1);
        assert_eq!(
            detail.tasks[0].suggested_fix.as_deref(),
            Some("resolve runtime-session ids through daemon index")
        );
    });
}

#[test]
fn change_role_records_reason_from_request() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon role request",
            "",
            project,
            Some("claude"),
            Some("daemon-role"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("role-worker"))], || {
            session_service::join_session(
                "daemon-role",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join worker")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|agent_id| agent_id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        append_project_ledger_entry(project);

        let _ = change_role(
            "daemon-role",
            &worker_id,
            &RoleChangeRequest {
                actor: leader_id,
                role: SessionRole::Reviewer,
                reason: Some("route triage through a reviewer".into()),
            },
            None,
        )
        .expect("change role");

        let entries = session_service::session_status("daemon-role", project)
            .expect("status")
            .tasks;
        assert!(entries.is_empty());
        let log_entries =
            crate::session::storage::load_log_entries_legacy(project, "daemon-role").expect("log");
        assert!(log_entries.into_iter().any(|entry| {
            entry.reason.as_deref() == Some("route triage through a reviewer")
                && matches!(
                    entry.transition,
                    crate::session::types::SessionTransition::RoleChanged { ref agent_id, .. }
                        if agent_id == &worker_id
                )
        }));
    });
}

#[test]
fn create_assign_and_checkpoint_task_async_round_trip() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-task-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");

                let state = start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async task mutation".into(),
                        context: "async task flow".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-async-task".into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "daemon-async-task",
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

                let created = create_task_async(
                    "daemon-async-task",
                    &TaskCreateRequest {
                        actor: leader_id.clone(),
                        title: "async task".into(),
                        context: Some("drive from async DB".into()),
                        severity: crate::session::types::TaskSeverity::Medium,
                        suggested_fix: None,
                    },
                    &async_db,
                )
                .await
                .expect("create task");
                let task_id = created.tasks[0].task_id.clone();

                let assigned = assign_task_async(
                    "daemon-async-task",
                    &task_id,
                    &TaskAssignRequest {
                        actor: leader_id.clone(),
                        agent_id: worker_id.clone(),
                    },
                    &async_db,
                )
                .await
                .expect("assign task");
                assert_eq!(
                    assigned.tasks[0].assigned_to.as_deref(),
                    Some(worker_id.as_str())
                );

                let checkpointed = checkpoint_task_async(
                    "daemon-async-task",
                    &task_id,
                    &TaskCheckpointRequest {
                        actor: leader_id,
                        summary: "async half done".into(),
                        progress: 50,
                    },
                    &async_db,
                )
                .await
                .expect("checkpoint task");
                assert_eq!(
                    checkpointed.tasks[0]
                        .checkpoint_summary
                        .as_ref()
                        .map(|summary| summary.summary.as_str()),
                    Some("async half done")
                );
            });
        });
    });
}

#[test]
fn change_role_and_transfer_leader_async_update_session_state() {
    with_temp_project(|project| {
        temp_env::with_var("CODEX_SESSION_ID", Some("async-role-worker"), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = project
                    .parent()
                    .expect("project parent")
                    .join("daemon.sqlite");
                let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");

                let state = start_session_direct_async(
                    &crate::daemon::protocol::SessionStartRequest {
                        title: "async role mutation".into(),
                        context: "async role flow".into(),
                        runtime: "claude".into(),
                        session_id: Some("daemon-async-role".into()),
                        project_dir: project.to_string_lossy().into(),
                        policy_preset: None,
                    },
                    &async_db,
                )
                .await
                .expect("start session");
                let leader_id = state.leader_id.clone().expect("leader id");
                let joined = join_session_direct_async(
                    "daemon-async-role",
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

                let changed = change_role_async(
                    "daemon-async-role",
                    &worker_id,
                    &RoleChangeRequest {
                        actor: leader_id.clone(),
                        role: SessionRole::Reviewer,
                        reason: Some("async review routing".into()),
                    },
                    &async_db,
                )
                .await
                .expect("change role");
                let role = changed
                    .agents
                    .iter()
                    .find(|agent| agent.agent_id == worker_id)
                    .map(|agent| agent.role);
                assert_eq!(role, Some(SessionRole::Reviewer));

                let transferred = transfer_leader_async(
                    "daemon-async-role",
                    &LeaderTransferRequest {
                        actor: leader_id,
                        new_leader_id: worker_id.clone(),
                        reason: Some("async handoff".into()),
                    },
                    &async_db,
                )
                .await
                .expect("transfer leader");
                assert_eq!(
                    transferred.session.leader_id.as_deref(),
                    Some(worker_id.as_str())
                );
            });
        });
    });
}

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

                    let state = start_session_direct_async(
                        &crate::daemon::protocol::SessionStartRequest {
                            title: "async task lifecycle".into(),
                            context: "async task lifecycle flow".into(),
                            runtime: "claude".into(),
                            session_id: Some("daemon-async-task-lifecycle".into()),
                            project_dir: project.to_string_lossy().into(),
                            policy_preset: None,
                        },
                        &async_db,
                    )
                    .await
                    .expect("start session");
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
