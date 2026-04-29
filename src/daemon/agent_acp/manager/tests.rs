use std::fs;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::permission_bridge::DEFAULT_PERMISSION_CAP;

fn manager() -> AcpAgentManagerHandle {
    let (sender, _) = broadcast::channel(16);
    AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()))
}

fn manager_with_events() -> (
    AcpAgentManagerHandle,
    broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
) {
    let (sender, receiver) = broadcast::channel(64);
    (
        AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new())),
        receiver,
    )
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

fn wait_until_disconnected(manager: &AcpAgentManagerHandle, acp_id: &str) -> AcpAgentSnapshot {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let snapshot = manager.get(acp_id).expect("refresh");
        if matches!(snapshot.status, AgentStatus::Disconnected { .. }) {
            return snapshot;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for ACP process to disconnect"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
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
                reason: DisconnectReason::SessionStopped,
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
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");

        let deadline = Instant::now() + Duration::from_secs(2);
        let refreshed = loop {
            let refreshed = manager.get(&snapshot.acp_id).expect("refresh");
            if matches!(&refreshed.status, AgentStatus::Disconnected { .. }) {
                break refreshed;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for ACP process to disconnect"
            );
            std::thread::sleep(Duration::from_millis(50));
        };
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
        let saw_process_incident = (0..32).any(|_| match events.try_recv() {
            Ok(event) => event.event == "acp_process_incident",
            Err(_) => false,
        });
        assert!(saw_process_incident, "expected acp_process_incident event");
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

#[tokio::test]
#[cfg(unix)]
async fn process_key_changes_when_permission_mode_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 60\n");
        let descriptor = descriptor(&script);
        let manager = manager();
        let base = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };
        let recording = AcpAgentStartRequest {
            record_permissions: true,
            ..base.clone()
        };

        let first = manager
            .start_descriptor("sess-1", &base, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &recording, &descriptor)
            .expect("start second");
        assert_ne!(first.process_key, second.process_key);
        manager.stop(&first.acp_id).expect("stop first");
        manager.stop(&second.acp_id).expect("stop second");
    });
}

#[tokio::test]
#[cfg(unix)]
async fn process_key_changes_when_project_root_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let root_a = temp.path().join("a");
        let root_b = temp.path().join("b");
        fs::create_dir_all(&root_a).expect("mkdir a");
        fs::create_dir_all(&root_b).expect("mkdir b");
        let script = temp.path().join("fake-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 60\n");
        let descriptor = descriptor(&script);
        let manager = manager();
        let first = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(root_a.display().to_string()),
            record_permissions: false,
        };
        let second = AcpAgentStartRequest {
            project_dir: Some(root_b.display().to_string()),
            ..first.clone()
        };

        let one = manager
            .start_descriptor("sess-1", &first, &descriptor)
            .expect("start one");
        let two = manager
            .start_descriptor("sess-2", &second, &descriptor)
            .expect("start two");
        assert_ne!(one.process_key, two.process_key);
        manager.stop(&one.acp_id).expect("stop one");
        manager.stop(&two.acp_id).expect("stop two");
    });
}

#[tokio::test]
#[cfg(unix)]
async fn process_key_stable_for_unlisted_env_drift() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 60\n");
        let descriptor = descriptor(&script);
        let manager = manager();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };

        let first = temp_env::with_var("HARNESS_TEST_NOISE", Some("a"), || {
            manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start first")
        });
        let second = temp_env::with_var("HARNESS_TEST_NOISE", Some("b"), || {
            manager
                .start_descriptor("sess-2", &request, &descriptor)
                .expect("start second")
        });
        assert_eq!(first.process_key, second.process_key);
        manager.stop(&first.acp_id).expect("stop first");
        manager.stop(&second.acp_id).expect("stop second");
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

            let error = manager()
                .start("sess-1", &request)
                .expect_err("sandbox must refuse ACP");
            let rendered = format!("{error}");
            assert!(
                rendered.contains("sandbox feature disabled: acp.host-bridge"),
                "unexpected error: {rendered}"
            );
        },
    );
}

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

#[tokio::test]
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
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
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
        assert!(saw_quarantine_applied, "expected quarantine-applied incident");

        let error = manager
            .start_descriptor("sess-4", &request, &descriptor)
            .expect_err("quarantined process key should be blocked");
        assert!(
            format!("{error}").contains("quarantined"),
            "unexpected error: {error}"
        );
    });
}

#[tokio::test]
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
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
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

#[tokio::test]
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
                prompt: None,
                project_dir: Some(temp.path().display().to_string()),
                record_permissions: false,
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
