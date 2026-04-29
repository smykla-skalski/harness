use std::fs;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};

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

#[tokio::test]
#[cfg(unix)]
async fn identical_process_contract_reuses_one_child_for_multiple_logical_sessions() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, request) = shared_fake_runtime();

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start second");

        assert_ne!(first.acp_id, second.acp_id);
        assert_eq!(first.process_key, second.process_key);
        assert_eq!(first.pid, second.pid);
        assert_eq!(first.pgid, second.pgid);
        assert_eq!(manager.list("sess-1").expect("list first").len(), 1);
        assert_eq!(manager.list("sess-2").expect("list second").len(), 1);

        manager.stop(&first.acp_id).expect("stop first");
        manager.stop(&second.acp_id).expect("stop second");
    });
}

#[tokio::test]
#[cfg(unix)]
async fn stopping_one_reused_process_session_keeps_sibling_active() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, request) = shared_fake_runtime();

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start second");

        manager.stop(&first.acp_id).expect("stop first");
        let sibling = manager.get(&second.acp_id).expect("get sibling");
        assert_eq!(first.pid, sibling.pid);
        assert_eq!(sibling.status, AgentStatus::Active);

        let stopped_again = manager.stop(&first.acp_id).expect("stop first again");
        assert!(stopped_again.status.is_disconnected());
        assert_eq!(
            manager.get(&second.acp_id).expect("get sibling").status,
            AgentStatus::Active
        );

        manager.stop(&second.acp_id).expect("stop second");
        assert_eq!(process_count(&manager), 0);
    });
}

#[cfg(unix)]
fn shared_fake_runtime() -> (
    TempDir,
    AcpAgentManagerHandle,
    AcpAgentDescriptor,
    AcpAgentStartRequest,
) {
    let temp = TempDir::new().expect("temp");
    let script = temp.path().join("fake-agent.sh");
    write_executable(&script, "#!/bin/sh\nsleep 60\n");
    let descriptor = descriptor(&script);
    let request = AcpAgentStartRequest {
        agent: "fake".to_string(),
        prompt: None,
        project_dir: Some(temp.path().display().to_string()),
        record_permissions: false,
    };
    (temp, manager(), descriptor, request)
}

#[tokio::test]
#[cfg(unix)]
async fn process_exit_disconnects_every_reused_logical_session() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 0.2\nexit 7\n");
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start second");
        assert_eq!(first.pid, second.pid);

        let disconnected = wait_until_disconnected(&manager, &first.acp_id);
        assert!(matches!(
            disconnected.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));
        assert!(
            manager
                .get(&second.acp_id)
                .expect("get sibling")
                .status
                .is_disconnected()
        );

        let incident = next_process_incident(&mut events);
        assert_eq!(
            incident.payload["affected_logical_session_ids"],
            serde_json::json!(["sess-1", "sess-2"])
        );
    });
}

#[tokio::test]
#[cfg(unix)]
async fn process_exit_after_logical_stop_reports_only_remaining_sessions() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\nsleep 0.2\nexit 7\n");
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start second");
        manager.stop(&first.acp_id).expect("stop first");

        let disconnected = wait_until_disconnected(&manager, &second.acp_id);
        assert!(matches!(
            disconnected.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));

        let incident = next_process_incident(&mut events);
        assert_eq!(
            incident.payload["affected_logical_session_ids"],
            serde_json::json!(["sess-2"])
        );
        assert_eq!(process_count(&manager), 0);
    });
}

fn process_count(manager: &AcpAgentManagerHandle) -> usize {
    manager
        .state
        .processes
        .lock()
        .expect("ACP processes lock")
        .len()
}

fn wait_until_disconnected(manager: &AcpAgentManagerHandle, acp_id: &str) -> AcpAgentSnapshot {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let snapshot = manager.get(acp_id).expect("refresh");
        if snapshot.status.is_disconnected() {
            return snapshot;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for ACP process to disconnect"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn next_process_incident(
    events: &mut broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
) -> crate::daemon::protocol::StreamEvent {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Ok(event) = events.try_recv()
            && event.event == "acp_process_incident"
        {
            return event;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for process incident"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}
