use super::*;

#[test]
fn build_recovery_tui_request_accepts_awaiting_leader_and_leaderless_degraded_sessions() {
    with_temp_project(|project| {
        start_session_with_policy(
            "awaiting recovery",
            "",
            project,
            Some("00000000-0000-4002-8000-00000000001e"),
            Some("swarm-default"),
        )
        .expect("start leaderless session");

        let awaiting = build_recovery_tui_request(
            "00000000-0000-4002-8000-00000000001e",
            "swarm-default",
            "codex",
            project,
        )
        .expect("awaiting leader should accept recovery");
        assert_eq!(awaiting.runtime, "codex");
        assert_eq!(awaiting.role, SessionRole::Leader);

        let degraded = start_active_session_with_policy(
            "degraded recovery",
            "",
            project,
            Some("claude"),
            Some("00000000-0000-4002-8000-00000000003c"),
            Some("swarm-default"),
        )
        .expect("start active session");
        let degraded_leader = degraded.leader_id.expect("leader");
        let layout =
            storage::layout_from_project_dir(project, "00000000-0000-4002-8000-00000000003c")
                .expect("layout");
        storage::update_state(&layout, |state| {
            state.status = SessionStatus::LeaderlessDegraded;
            state.leader_id = None;
            state
                .agents
                .get_mut(&degraded_leader)
                .expect("leader")
                .status = AgentStatus::disconnected_unknown();
            Ok(())
        })
        .expect("degrade session");

        let degraded_request = build_recovery_tui_request(
            "00000000-0000-4002-8000-00000000003c",
            "swarm-default",
            "claude",
            project,
        )
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
            Some("00000000-0000-4002-8000-00000000001d"),
            Some("swarm-default"),
        )
        .expect("start active session");
        let active_error = build_recovery_tui_request(
            "00000000-0000-4002-8000-00000000001d",
            "swarm-default",
            "codex",
            project,
        )
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
        let ended_error = build_recovery_tui_request(
            "00000000-0000-4002-8000-00000000001d",
            "swarm-default",
            "codex",
            project,
        )
        .expect_err("ended sessions must reject managed recovery");
        assert!(ended_error.to_string().contains(
            "leader recovery is only valid for awaiting_leader or leaderless_degraded sessions"
        ));
    });
}
