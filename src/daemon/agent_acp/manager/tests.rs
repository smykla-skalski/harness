use std::fs;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::daemon::agent_acp::permission_bridge::DEFAULT_PERMISSION_CAP;

fn manager() -> AcpAgentManagerHandle {
    let (sender, _) = broadcast::channel(16);
    AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()))
}

fn descriptor(command: &Path) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "fake".to_string(),
        display_name: "Fake ACP".to_string(),
        capabilities: Vec::new(),
        launch_command: command.display().to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        model_catalog: None,
        install_hint: None,
        doctor_probe: catalog::DoctorProbe {
            command: command.display().to_string(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
    }
}

#[cfg(unix)]
fn write_executable(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;

    fs::write(path, body).expect("write script");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("chmod script");
}

#[tokio::test]
#[cfg(unix)]
async fn start_list_stop_tracks_live_snapshot() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 60\n");
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");

        let listed = manager.list("sess-1").expect("list");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].acp_id, snapshot.acp_id);

        let inspected = manager.inspect(Some("sess-1"));
        assert_eq!(inspected.agents.len(), 1);
        assert_eq!(inspected.agents[0].acp_id, snapshot.acp_id);
        assert_eq!(inspected.agents[0].agent_id, "fake");
        assert_eq!(inspected.agents[0].watchdog_state, "active");
        assert_eq!(inspected.agents[0].permission_mode, "daemon_bridge");
        assert_eq!(inspected.agents[0].permission_queue_depth, 0);
        assert_eq!(inspected.agents[0].permission_log_path, None);
        assert!(!inspected.agents[0].process_key.is_empty());

        let stopped = manager.stop(&snapshot.acp_id).expect("stop");
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::UserCancelled,
                ..
            }
        ));
    });
}

#[tokio::test]
#[cfg(unix)]
async fn abnormal_exit_populates_disconnect_reason_and_stderr_tail() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\necho boom >&2\nexit 7\n");
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");

        std::thread::sleep(Duration::from_millis(100));
        let refreshed = manager.get(&snapshot.acp_id).expect("refresh");
        assert!(matches!(
            refreshed.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited {
                    code: Some(7),
                    signal: None
                },
                ..
            }
        ));
        let AgentStatus::Disconnected { stderr_tail, .. } = refreshed.status else {
            panic!("expected disconnected status");
        };
        assert!(stderr_tail.expect("stderr tail").contains("boom"));
    });
}

#[tokio::test]
#[cfg(unix)]
async fn start_recording_mode_surfaces_log_path_in_inspect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let xdg = temp.path().join("xdg");
        temp_env::with_var("XDG_DATA_HOME", Some(&xdg), || {
            let script = temp.path().join("fake-agent.sh");
            write_executable(&script, "#!/bin/sh\nsleep 60\n");
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                prompt: None,
                project_dir: Some(temp.path().display().to_string()),
                record_permissions: true,
            };
            let manager = manager();
            let descriptor = descriptor(&script);
            let snapshot = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start");

            assert_eq!(snapshot.permission_mode, "recording");
            assert_eq!(
                snapshot.permission_log_path.as_deref(),
                Some(
                    xdg.join("harness")
                        .join("runs")
                        .join("sess-1")
                        .join("permission-log.ndjson")
                        .to_str()
                        .expect("utf8 log path")
                )
            );

            let inspected = manager.inspect(Some("sess-1"));
            assert_eq!(inspected.agents[0].permission_mode, "recording");
            assert_eq!(
                inspected.agents[0].permission_log_path,
                snapshot.permission_log_path
            );
            assert_eq!(inspected.agents[0].process_key, snapshot.process_key);

            manager.stop(&snapshot.acp_id).expect("stop");
        });
    });
}

#[test]
fn default_permission_cap_matches_plan() {
    assert_eq!(DEFAULT_PERMISSION_CAP, 8);
}

#[test]
fn start_rejects_sandboxed_daemon_mode() {
    temp_env::with_vars(
        [
            (feature_flags::ACP_ENV, Some("1")),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        || {
            let request = AcpAgentStartRequest {
                agent: "copilot".to_string(),
                prompt: None,
                project_dir: None,
                record_permissions: false,
            };

            let error = manager().start("sess-1", &request).expect_err("sandbox must refuse ACP");
            let rendered = format!("{error}");
            assert!(
                rendered.contains("sandbox feature disabled: acp.local-spawn"),
                "unexpected error: {rendered}"
            );
        },
    );
}
