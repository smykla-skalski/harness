use super::*;

#[test]
fn process_fault_policy_env_toggle_parsing() {
    temp_env::with_var("HARNESS_ACP_PROCESS_FAULT_POLICY", Some("0"), || {
        assert!(!process_fault_policy_enabled());
    });
    temp_env::with_var("HARNESS_ACP_PROCESS_FAULT_POLICY", Some("false"), || {
        assert!(!process_fault_policy_enabled());
    });
    temp_env::with_var("HARNESS_ACP_PROCESS_FAULT_POLICY", Some("off"), || {
        assert!(!process_fault_policy_enabled());
    });
    temp_env::with_var("HARNESS_ACP_PROCESS_FAULT_POLICY", Some("1"), || {
        assert!(process_fault_policy_enabled());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn repeated_process_faults_quarantine_process_key() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\nexit 7\n");
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };

        let mut saw_quarantine_applied = false;
        let mut saw_backoff_applied = false;
        for idx in 1..=3 {
            let snapshot = manager
                .start_descriptor(&format!("sess-{idx}"), &request, &descriptor)
                .expect("start failing session");
            let disconnected = wait_until_disconnected(&manager, &snapshot.acp_id);
            assert!(matches!(
                disconnected.status,
                AgentStatus::Disconnected {
                    reason: DisconnectReason::ProcessExited { .. },
                    ..
                }
            ));
            for _ in 0..32 {
                let Ok(event) = events.try_recv() else {
                    continue;
                };
                if event.event == "acp_process_incident"
                    && event.payload["backoff_applied"] == serde_json::Value::Bool(true)
                {
                    saw_backoff_applied = true;
                }
                if event.event == "acp_process_incident"
                    && event.payload["quarantine_applied"] == serde_json::Value::Bool(true)
                {
                    saw_quarantine_applied = true;
                }
            }
            std::thread::sleep(Duration::from_millis(1100));
        }
        assert!(saw_backoff_applied, "expected backoff-applied incident");
        assert!(
            saw_quarantine_applied,
            "expected quarantine-applied incident"
        );

        let error = manager
            .start_descriptor("sess-4", &request, &descriptor)
            .expect_err("quarantined process key should be blocked");
        assert!(
            format!("{error}").contains("quarantined"),
            "unexpected error: {error}"
        );
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn recent_process_fault_applies_backoff_before_next_start() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\nexit 7\n");
        let descriptor = descriptor(&script);
        let manager = manager();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first failing session");
        let _ = wait_until_disconnected(&manager, &first.acp_id);

        let error = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect_err("immediate restart should be backoff-blocked");
        assert!(
            format!("{error}").contains("backoff"),
            "unexpected error: {error}"
        );

        std::thread::sleep(Duration::from_millis(1100));
        let restarted = manager
            .start_descriptor("sess-3", &request, &descriptor)
            .expect("start after backoff window");
        let _ = wait_until_disconnected(&manager, &restarted.acp_id);
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_fault_policy_disabled_skips_backoff_and_quarantine_enforcement() {
    temp_env::with_vars(
        [
            (feature_flags::ACP_ENV, Some("1")),
            ("HARNESS_ACP_PROCESS_FAULT_POLICY", Some("0")),
        ],
        || {
            let temp = TempDir::new().expect("temp");
            let script = temp.path().join("failing-agent.sh");
            write_executable(&script, "#!/bin/sh\nexit 7\n");
            let descriptor = descriptor(&script);
            let manager = manager();
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                project_dir: Some(temp.path().display().to_string()),
                ..AcpAgentStartRequest::default()
            };

            let first = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start first");
            let _ = wait_until_disconnected(&manager, &first.acp_id);

            let second = manager
                .start_descriptor("sess-2", &request, &descriptor)
                .expect("start second without backoff block");
            let _ = wait_until_disconnected(&manager, &second.acp_id);
        },
    );
}
