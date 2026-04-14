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
            crate::session::storage::load_log_entries(project, "daemon-role").expect("log");
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
