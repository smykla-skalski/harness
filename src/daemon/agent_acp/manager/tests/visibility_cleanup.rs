use super::*;

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn stopped_agents_disappear_from_list_and_inspect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");

        manager.stop(&snapshot.acp_id).expect("stop");

        assert!(
            manager.list("sess-1").expect("list after stop").is_empty(),
            "stopped ACP agents should not remain in managed-agent listings"
        );
        assert!(
            manager
                .inspect(Some("sess-1"))
                .expect("inspect after stop")
                .agents
                .is_empty(),
            "stopped ACP agents should not remain in inspect results"
        );
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn failed_starts_rollback_and_disappear_from_list_and_inspect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\necho boom >&2\nexit 7\n");
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");

        let _ = wait_until_disconnected(&manager, &snapshot.acp_id);

        assert!(
            manager
                .list("sess-1")
                .expect("list after failure")
                .is_empty(),
            "failed ACP starts should not stay visible in managed-agent listings"
        );
        assert!(
            manager
                .inspect(Some("sess-1"))
                .expect("inspect after failure")
                .agents
                .is_empty(),
            "failed ACP starts should not stay visible in inspect results"
        );
        let state = load_session_state(&manager, "sess-1");
        assert!(
            state.agents.values().all(|agent| {
                agent.managed_agent != Some(ManagedAgentRef::acp(&snapshot.acp_id))
            }),
            "failed ACP starts should roll back incomplete orchestration registrations"
        );
    });
}
