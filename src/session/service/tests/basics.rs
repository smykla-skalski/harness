use super::*;

#[test]
fn start_creates_leaderless_session() {
    with_temp_project(|project| {
        let state = start_session("test goal", "", project, None).expect("start");
        assert_eq!(state.status, SessionStatus::AwaitingLeader);
        assert!(state.leader_id.is_none());
        assert!(state.agents.is_empty());
        assert_eq!(state.metrics.agent_count, 0);
        assert_eq!(state.metrics.active_agent_count, 0);
    });
}

#[test]
fn join_adds_agent() {
    with_temp_project(|project| {
        let state = start_session("test", "", project, Some("s1")).expect("start");
        let state = join_session(
            &state.session_id,
            SessionRole::Worker,
            "codex",
            &["general".into()],
            None,
            project,
            None,
        )
        .expect("join");
        assert_eq!(state.status, SessionStatus::AwaitingLeader);
        assert!(state.leader_id.is_none());
        assert_eq!(state.agents.len(), 1);
        assert_eq!(state.metrics.agent_count, 1);
    });
}

#[test]
fn join_session_downgrades_requested_leader_to_explicit_fallback_role() {
    with_temp_project(|project| {
        let state = start_active_session_with_policy(
            "swarm contract",
            "",
            project,
            Some("claude"),
            Some("join-fallback-core"),
            Some("swarm-default"),
        )
        .expect("start");
        let leader_id = state.leader_id.clone().expect("leader");

        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("fallback-candidate"), || {
            join_session_with_fallback(
                "join-fallback-core",
                SessionRole::Leader,
                Some(SessionRole::Improver),
                "codex",
                &["priority:90".into()],
                Some("fallback candidate"),
                project,
                None,
            )
        })
        .expect("join");

        let improver = joined
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex agent");
        assert_eq!(improver.role, SessionRole::Improver);
        assert_eq!(joined.leader_id.as_deref(), Some(leader_id.as_str()));
    });
}

#[test]
fn join_session_recovers_leaderless_degraded_session_with_manual_leader_join() {
    with_temp_project(|project| {
        start_active_session_with_policy(
            "swarm contract",
            "",
            project,
            Some("claude"),
            Some("recover-manual"),
            Some("swarm-default"),
        )
        .expect("start");
        let layout = storage::layout_from_project_dir(project, "recover-manual").expect("layout");
        storage::update_state(&layout, |state| {
            let previous_leader = state.leader_id.take().expect("leader");
            state.status = SessionStatus::LeaderlessDegraded;
            let leader = state
                .agents
                .get_mut(&previous_leader)
                .expect("leader registration");
            leader.status = AgentStatus::Disconnected;
            Ok(())
        })
        .expect("degrade session");

        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("manual-recovery"), || {
            join_session_with_fallback(
                "recover-manual",
                SessionRole::Leader,
                None,
                "codex",
                &["priority:90".into()],
                Some("Recovered leader"),
                project,
                None,
            )
        })
        .expect("recover leader");

        let recovered = joined
            .leader_id
            .as_deref()
            .and_then(|leader_id| joined.agents.get(leader_id))
            .expect("recovered leader");
        assert_eq!(joined.status, SessionStatus::Active);
        assert_eq!(recovered.runtime, "codex");
        assert_eq!(recovered.role, SessionRole::Leader);
    });
}

#[test]
fn build_recovery_tui_request_accepts_awaiting_leader_and_leaderless_degraded_sessions() {
    with_temp_project(|project| {
        start_session_with_policy(
            "awaiting recovery",
            "",
            project,
            Some("recover-awaiting"),
            Some("swarm-default"),
        )
        .expect("start leaderless session");

        let awaiting =
            build_recovery_tui_request("recover-awaiting", "swarm-default", "codex", project)
                .expect("awaiting leader should accept recovery");
        assert_eq!(awaiting.runtime, "codex");
        assert_eq!(awaiting.role, SessionRole::Leader);

        let degraded = start_active_session_with_policy(
            "degraded recovery",
            "",
            project,
            Some("claude"),
            Some("recover-degraded"),
            Some("swarm-default"),
        )
        .expect("start active session");
        let degraded_leader = degraded.leader_id.clone().expect("leader");
        let layout = storage::layout_from_project_dir(project, "recover-degraded").expect("layout");
        storage::update_state(&layout, |state| {
            state.status = SessionStatus::LeaderlessDegraded;
            state.leader_id = None;
            state
                .agents
                .get_mut(&degraded_leader)
                .expect("leader")
                .status = AgentStatus::Disconnected;
            Ok(())
        })
        .expect("degrade session");

        let degraded_request =
            build_recovery_tui_request("recover-degraded", "swarm-default", "claude", project)
                .expect("leaderless degraded should accept recovery");
        assert_eq!(degraded_request.runtime, "claude");
        assert_eq!(degraded_request.role, SessionRole::Leader);
    });
}

#[test]
fn build_recovery_tui_request_rejects_active_and_ended_sessions() {
    with_temp_project(|project| {
        let active = start_active_session_with_policy(
            "active recovery reject",
            "",
            project,
            Some("claude"),
            Some("recover-active"),
            Some("swarm-default"),
        )
        .expect("start active session");
        let active_error =
            build_recovery_tui_request("recover-active", "swarm-default", "codex", project)
                .expect_err("active sessions must reject managed recovery");
        assert!(active_error.to_string().contains(
            "leader recovery is only valid for awaiting_leader or leaderless_degraded sessions"
        ));

        end_session(
            &active.session_id,
            active.leader_id.as_deref().expect("leader"),
            project,
        )
        .expect("end session");
        let ended_error =
            build_recovery_tui_request("recover-active", "swarm-default", "codex", project)
                .expect_err("ended sessions must reject managed recovery");
        assert!(ended_error.to_string().contains(
            "leader recovery is only valid for awaiting_leader or leaderless_degraded sessions"
        ));
    });
}

#[test]
fn start_session_rejects_duplicate_session_id() {
    with_temp_project(|project| {
        start_session("goal1", "", project, Some("dup")).expect("first");
        let error = start_session("goal2", "", project, Some("dup")).expect_err("dup");

        assert_eq!(error.code(), "KSRCLI092");
        assert_eq!(
            session_status("dup", project).expect("status").context,
            "goal1"
        );
    });
}

#[test]
fn start_session_rejects_unsafe_session_id() {
    with_temp_project(|project| {
        let tmp_root = project.parent().expect("parent");
        let escape_dir = tmp_root.join("unsafe-session");
        let unsafe_id = escape_dir.to_string_lossy().into_owned();

        let error = start_session("goal", "", project, Some(&unsafe_id)).expect_err("id");

        assert_eq!(error.code(), "KSRCLI059");
        assert!(!escape_dir.join("state.json").exists());
    });
}

#[test]
fn start_session_with_policy_rejects_unknown_preset() {
    with_temp_project(|project| {
        let error = start_session_with_policy(
            "goal",
            "",
            project,
            Some("unknown-preset"),
            Some("swarm-future"),
        )
        .expect_err("unknown preset should be rejected");

        assert_eq!(error.code(), "KSRCLI092");
        assert!(
            error
                .to_string()
                .contains("unknown session policy preset 'swarm-future'"),
            "unexpected error: {error}"
        );
    });
}

#[test]
fn auto_generated_session_ids_are_unique() {
    with_temp_project(|project| {
        let first = start_session("goal1", "", project, None).expect("first");
        let second = start_session("goal2", "", project, None).expect("second");
        assert_ne!(first.session_id, second.session_id);
    });
}

#[test]
fn join_same_runtime_keeps_distinct_agents() {
    with_temp_project(|project| {
        start_active_session("test", "", project, Some("claude"), Some("join-unique"))
            .expect("start");

        let (first, second) =
            temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
                let first = join_session(
                    "join-unique",
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("first");
                let second = join_session(
                    "join-unique",
                    SessionRole::Reviewer,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
                )
                .expect("second");
                (first, second)
            });

        assert_eq!(first.agents.len(), 2);
        assert_eq!(second.agents.len(), 3);
        let codex_ids: Vec<_> = second
            .agents
            .keys()
            .filter(|id| id.starts_with("codex-"))
            .collect();
        assert_eq!(codex_ids.len(), 2);
    });
}

#[test]
fn join_records_runtime_session_id_when_available() {
    with_temp_project(|project| {
        start_active_session("test", "", project, Some("claude"), Some("join-runtime")).unwrap();

        let joined = temp_env::with_vars([("CODEX_SESSION_ID", Some("codex-worker"))], || {
            join_session(
                "join-runtime",
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .unwrap()
        });

        let codex_worker = joined
            .agents
            .values()
            .find(|agent| agent.runtime == "codex")
            .expect("codex worker should be present");
        assert_eq!(
            codex_worker.agent_session_id.as_deref(),
            Some("codex-worker")
        );
    });
}

#[test]
fn end_session_requires_leader() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("s2")).expect("start");
        let joined = join_session(
            &state.session_id,
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
            .find(|id| id.starts_with("codex"))
            .expect("worker id")
            .clone();
        let result = end_session(&state.session_id, &worker_id, project);
        assert!(result.is_err());
    });
}

#[test]
fn task_lifecycle() {
    with_temp_project(|project| {
        let state =
            start_active_session("test", "", project, Some("claude"), Some("s3")).expect("start");
        let leader_id = state.leader_id.expect("leader id");

        let item = create_task(
            "s3",
            "fix bug",
            Some("details"),
            TaskSeverity::High,
            &leader_id,
            project,
        )
        .expect("task");
        assert_eq!(item.status, TaskStatus::Open);

        let tasks = list_tasks("s3", None, project).expect("list");
        assert_eq!(tasks.len(), 1);

        update_task(
            "s3",
            &item.task_id,
            TaskStatus::Done,
            Some("fixed"),
            &leader_id,
            project,
        )
        .expect("update");

        let tasks = list_tasks("s3", Some(TaskStatus::Done), project).expect("done");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].notes.len(), 1);
        assert!(tasks[0].completed_at.is_some());
    });
}
