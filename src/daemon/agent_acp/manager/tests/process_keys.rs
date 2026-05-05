use std::fs;

use super::*;

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_recording_mode_surfaces_log_path_in_inspect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let xdg = temp.path().join("xdg");
        temp_env::with_var("XDG_DATA_HOME", Some(&xdg), || {
            let script = temp.path().join("fake-agent.sh");
            write_sleeping_acp_agent(&script);
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                project_dir: Some(temp.path().display().to_string()),
                record_permissions: true,
                ..AcpAgentStartRequest::default()
            };
            let manager = manager();
            let descriptor = descriptor(&script);
            let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
                unreachable!();
            };

            let expected_log_path = xdg
                .join("harness")
                .join("runs")
                .join("sess-1")
                .join("permission-log.ndjson")
                .to_string_lossy()
                .into_owned();
            assert_eq!(snapshot.permission_mode, "recording");
            assert_eq!(
                snapshot.permission_log_path.as_deref(),
                Some(expected_log_path.as_str())
            );

            let Ok(inspected) = manager.inspect(Some("sess-1")) else {
                unreachable!();
            };
            assert_eq!(inspected.agents[0].permission_mode, "recording");
            assert_eq!(
                inspected.agents[0].permission_log_path,
                snapshot.permission_log_path
            );
            assert_eq!(inspected.agents[0].process_key, snapshot.process_key);

            assert!(manager.stop(&snapshot.acp_id).is_ok());
        });
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_changes_when_permission_mode_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let descriptor = descriptor(&script);
        let manager = manager();
        let base = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let recording = AcpAgentStartRequest {
            record_permissions: true,
            ..base.clone()
        };

        let Ok(first) = manager.start_descriptor("sess-1", &base, &descriptor) else {
            unreachable!();
        };
        let Ok(second) = manager.start_descriptor("sess-2", &recording, &descriptor) else {
            unreachable!();
        };
        assert_ne!(first.process_key, second.process_key);
        assert!(manager.stop(&first.acp_id).is_ok());
        assert!(manager.stop(&second.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_changes_when_project_root_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let root_a = temp.path().join("a");
        let root_b = temp.path().join("b");
        assert!(fs::create_dir_all(&root_a).is_ok());
        assert!(fs::create_dir_all(&root_b).is_ok());
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let descriptor = descriptor(&script);
        let manager = manager();
        let first = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(root_a.display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let second = AcpAgentStartRequest {
            project_dir: Some(root_b.display().to_string()),
            ..first.clone()
        };

        let Ok(one) = manager.start_descriptor("sess-1", &first, &descriptor) else {
            unreachable!();
        };
        let Ok(two) = manager.start_descriptor("sess-2", &second, &descriptor) else {
            unreachable!();
        };
        assert_ne!(one.process_key, two.process_key);
        assert!(manager.stop(&one.acp_id).is_ok());
        assert!(manager.stop(&two.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_stable_for_unlisted_env_drift() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let descriptor = descriptor(&script);
        let manager = manager();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };

        let first = temp_env::with_var("HARNESS_TEST_NOISE", Some("a"), || {
            let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
                unreachable!();
            };
            snapshot
        });
        let second = temp_env::with_var("HARNESS_TEST_NOISE", Some("b"), || {
            let Ok(snapshot) = manager.start_descriptor("sess-2", &request, &descriptor) else {
                unreachable!();
            };
            snapshot
        });
        assert_eq!(first.process_key, second.process_key);
        assert!(manager.stop(&first.acp_id).is_ok());
        assert!(manager.stop(&second.acp_id).is_ok());
    });
}
