use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    seeded_manager_with_events, write_sleeping_acp_agent,
};
use crate::feature_flags;

fn manager_with_events() -> (
    AcpAgentManagerHandle,
    broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
) {
    seeded_manager_with_events()
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

fn count_events(
    receiver: &mut broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
) -> (usize, usize) {
    let mut incident_count = 0;
    let mut disconnected_count = 0;
    while let Ok(event) = receiver.try_recv() {
        match event.event.as_str() {
            "acp_process_incident" => incident_count += 1,
            "acp_agent_disconnected" => disconnected_count += 1,
            _ => {}
        }
    }
    (incident_count, disconnected_count)
}

fn process_count(manager: &AcpAgentManagerHandle) -> usize {
    manager
        .state
        .processes
        .lock()
        .expect("ACP processes lock")
        .len()
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn disconnect_forwarded_session_is_idempotent_after_first_disconnect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");
        let active = {
            let sessions = manager.state.sessions.lock().expect("sessions lock");
            Arc::downgrade(sessions.get(&snapshot.acp_id).expect("active session"))
        };

        let _ = count_events(&mut events);
        manager
            .disconnect_forwarded_session(&active, DisconnectReason::TransportClosed)
            .expect("first forwarded disconnect");

        let refreshed = wait_until_disconnected(&manager, &snapshot.acp_id);
        assert!(matches!(
            refreshed.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::TransportClosed,
                ..
            }
        ));
        let (first_incidents, first_disconnected) = count_events(&mut events);
        assert_eq!(first_incidents, 1);
        assert_eq!(first_disconnected, 1);

        manager
            .disconnect_forwarded_session(&active, DisconnectReason::TransportClosed)
            .expect("second forwarded disconnect");

        let (second_incidents, second_disconnected) = count_events(&mut events);
        assert_eq!(second_incidents, 0);
        assert_eq!(second_disconnected, 0);
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn refresh_and_forwarded_disconnect_race_still_emit_one_incident() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");
        let active = {
            let sessions = manager.state.sessions.lock().expect("sessions lock");
            Arc::downgrade(sessions.get(&snapshot.acp_id).expect("active session"))
        };

        let _ = count_events(&mut events);
        let lifecycle = manager
            .state
            .process_lifecycle
            .lock()
            .expect("process lifecycle lock");
        let refresh_manager = manager.clone();
        let refresh_acp_id = snapshot.acp_id.clone();
        let refresh = std::thread::spawn(move || refresh_manager.get(&refresh_acp_id));
        std::thread::sleep(Duration::from_millis(25));
        let disconnect_manager = manager.clone();
        let disconnect = std::thread::spawn(move || {
            disconnect_manager
                .disconnect_forwarded_session(&active, DisconnectReason::TransportClosed)
        });
        std::thread::sleep(Duration::from_millis(25));
        drop(lifecycle);

        refresh
            .join()
            .expect("refresh thread")
            .expect("refresh snapshot");
        disconnect
            .join()
            .expect("disconnect thread")
            .expect("forwarded disconnect");

        let refreshed = wait_until_disconnected(&manager, &snapshot.acp_id);
        assert!(matches!(
            refreshed.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::TransportClosed,
                ..
            }
        ));
        let (incidents, disconnected) = count_events(&mut events);
        assert_eq!(incidents, 1);
        assert_eq!(disconnected, 1);
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn poisoned_permission_bridge_lock_does_not_block_snapshot_or_stop_cleanup() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, _events) = manager_with_events();
        let descriptor = descriptor(&script);
        let snapshot = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start");
        let active = {
            let sessions = manager.state.sessions.lock().expect("sessions lock");
            Arc::clone(sessions.get(&snapshot.acp_id).expect("active session"))
        };
        let process = active.process();

        active.poison_permission_bridge_pending_lock_for_test();

        let refreshed = manager
            .get(&snapshot.acp_id)
            .expect("refresh with poisoned permissions");
        assert_eq!(refreshed.status, AgentStatus::Active);

        let stopped = manager.stop(&snapshot.acp_id).expect("stop after poison");
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));
        assert_eq!(process.logical_session_count(), 0);
        assert_eq!(process_count(&manager), 0);
    });
}
