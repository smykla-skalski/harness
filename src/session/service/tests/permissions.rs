use super::*;

#[test]
fn removed_agent_loses_mutation_permissions() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("perm")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "perm",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let task = create_task(
            "perm",
            "task1",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        remove_agent("perm", &worker_id, &leader_id, project).expect("remove");

        let error = update_task(
            "perm",
            &task.task_id,
            TaskStatus::Done,
            None,
            &worker_id,
            project,
        )
        .expect_err("permission");
        assert_eq!(error.code(), "KSRCLI091");
    });
}

#[test]
fn assign_role_rejects_leader_changes() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("roles")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "roles",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        let error = assign_role(
            "roles",
            &worker_id,
            SessionRole::Leader,
            None,
            &leader_id,
            project,
        )
        .expect_err("role");
        assert_eq!(error.code(), "KSRCLI092");
    });
}

#[test]
fn assign_task_requires_active_assignee() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("assign")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "assign",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();
        let task = create_task(
            "assign",
            "task1",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        remove_agent("assign", &worker_id, &leader_id, project).expect("remove");

        let error = assign_task("assign", &task.task_id, &worker_id, &leader_id, project)
            .expect_err("assign");
        assert_eq!(error.code(), "KSRCLI092");
    });
}

#[test]
fn improver_cannot_assign_tasks_under_swarm_contract() {
    with_temp_project(|project| {
        let state = start_session_with_policy(
            "assignment rules",
            "",
            project,
            Some("claude"),
            Some("assign-rules"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("improver"), || {
            join_session(
                "assign-rules",
                SessionRole::Improver,
                "codex",
                &[],
                Some("Improver"),
                project,
                None,
            )
            .expect("join improver")
        });
        let improver_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("improver id")
            .to_string();
        let task = create_task(
            "assign-rules",
            "task",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let error = assign_task(
            "assign-rules",
            &task.task_id,
            &improver_id,
            &improver_id,
            project,
        )
        .expect_err("improver should not assign");
        assert_eq!(error.code(), "KSRCLI091");
    });
}

#[test]
fn leader_cannot_assign_task_to_observer() {
    with_temp_project(|project| {
        let state = start_session_with_policy(
            "assignment rules",
            "",
            project,
            Some("claude"),
            Some("observer-assignee"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");
        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("observer"), || {
            join_session(
                "observer-assignee",
                SessionRole::Observer,
                "codex",
                &[],
                Some("Observer"),
                project,
                None,
            )
            .expect("join observer")
        });
        let observer_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("observer id")
            .to_string();
        let task = create_task(
            "observer-assignee",
            "task",
            None,
            TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("task");

        let error = assign_task(
            "observer-assignee",
            &task.task_id,
            &observer_id,
            &leader_id,
            project,
        )
        .expect_err("observer should be rejected");
        assert_eq!(error.code(), "KSRCLI092");
    });
}

#[test]
fn transfer_leader_requires_active_target() {
    with_temp_project(|project| {
        let state =
            start_session("test", "", project, Some("claude"), Some("transfer")).expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let joined = join_session(
            "transfer",
            SessionRole::Worker,
            "codex",
            &[],
            None,
            project,
            None,
        )
        .expect("join");
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        remove_agent("transfer", &worker_id, &leader_id, project).expect("remove");

        let error = transfer_leader("transfer", &worker_id, None, &leader_id, project)
            .expect_err("transfer");
        assert_eq!(error.code(), "KSRCLI092");
    });
}

#[test]
fn observer_transfer_leader_creates_pending_request() {
    with_temp_project(|project| {
        let state = start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("transfer-pending"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let observer =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                join_session(
                    "transfer-pending",
                    SessionRole::Observer,
                    "codex",
                    &[],
                    Some("observer"),
                    project,
                    None,
                )
                .expect("join observer")
            });
        let observer_id = observer
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("observer id")
            .clone();

        transfer_leader(
            "transfer-pending",
            &observer_id,
            Some("leader is overloaded"),
            &observer_id,
            project,
        )
        .expect("request transfer");

        let updated = session_status("transfer-pending", project).expect("status");
        assert_eq!(updated.leader_id.as_deref(), Some(leader_id.as_str()));
        let request = updated
            .pending_leader_transfer
            .as_ref()
            .expect("pending request");
        assert_eq!(request.requested_by, observer_id);
        assert_eq!(request.current_leader_id, leader_id);
        assert_eq!(request.new_leader_id, request.requested_by);
    });
}

#[test]
fn current_leader_confirms_pending_transfer() {
    with_temp_project(|project| {
        let state = start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("transfer-confirm"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let observer =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                join_session(
                    "transfer-confirm",
                    SessionRole::Observer,
                    "codex",
                    &[],
                    Some("observer"),
                    project,
                    None,
                )
                .expect("join observer")
            });
        let observer_id = observer
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("observer id")
            .clone();

        transfer_leader(
            "transfer-confirm",
            &observer_id,
            Some("codex is ready"),
            &observer_id,
            project,
        )
        .expect("request transfer");
        transfer_leader(
            "transfer-confirm",
            &observer_id,
            Some("approved"),
            &leader_id,
            project,
        )
        .expect("confirm transfer");

        let updated = session_status("transfer-confirm", project).expect("status");
        assert_eq!(updated.leader_id.as_deref(), Some(observer_id.as_str()));
        assert!(updated.pending_leader_transfer.is_none());

        let layout =
            storage::layout_from_project_dir(project, "transfer-confirm").expect("layout");
        let entries = storage::load_log_entries(&layout).expect("entries");
        assert!(entries.iter().any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::LeaderTransferRequested { .. }
            )
        }));
        assert!(entries.iter().any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::LeaderTransferConfirmed { .. }
            )
        }));
        assert!(entries.iter().any(|entry| {
            matches!(
                entry.transition,
                SessionTransition::LeaderTransferred { .. }
            )
        }));
    });
}

#[test]
fn observer_transfer_leader_succeeds_when_current_leader_is_unresponsive() {
    with_temp_project(|project| {
        let state = start_session(
            "test",
            "",
            project,
            Some("claude"),
            Some("transfer-timeout"),
        )
        .expect("start");
        let leader_id = state.leader_id.expect("leader id");
        let observer =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("observer-session"))], || {
                join_session(
                    "transfer-timeout",
                    SessionRole::Observer,
                    "codex",
                    &[],
                    Some("observer"),
                    project,
                    None,
                )
                .expect("join observer")
            });
        let observer_id = observer
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("observer id")
            .clone();

        let layout_timeout =
            storage::layout_from_project_dir(project, "transfer-timeout").expect("layout");
        storage::update_state(&layout_timeout, |state| {
            let stale = (Utc::now() - Duration::seconds(600)).to_rfc3339();
            let leader = state.agents.get_mut(&leader_id).expect("leader");
            leader.last_activity_at = Some(stale.clone());
            state.last_activity_at = Some(stale);
            Ok(())
        })
        .expect("mark stale");

        transfer_leader(
            "transfer-timeout",
            &observer_id,
            Some("leader timed out"),
            &observer_id,
            project,
        )
        .expect("forced transfer");

        let updated = session_status("transfer-timeout", project).expect("status");
        assert_eq!(updated.leader_id.as_deref(), Some(observer_id.as_str()));
        assert!(updated.pending_leader_transfer.is_none());
    });
}
