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
        spawn_configuration: Default::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration: Default::default(),
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
        let Ok(snapshot) = manager.get(acp_id) else {
            unreachable!("refresh");
        };
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
    let Ok(processes) = manager.state.processes.lock() else {
        unreachable!("ACP processes lock");
    };
    processes.len()
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn disconnect_forwarded_session_is_idempotent_after_first_disconnect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!("temp");
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!("start");
        };
        let active = {
            let Ok(sessions) = manager.state.sessions.lock() else {
                unreachable!("sessions lock");
            };
            let Some(session) = sessions.get(&snapshot.acp_id) else {
                unreachable!("active session");
            };
            Arc::downgrade(session)
        };

        let _ = count_events(&mut events);
        let Ok(()) =
            manager.disconnect_forwarded_session(&active, DisconnectReason::TransportClosed)
        else {
            unreachable!("first forwarded disconnect");
        };

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

        let Ok(()) =
            manager.disconnect_forwarded_session(&active, DisconnectReason::TransportClosed)
        else {
            unreachable!("second forwarded disconnect");
        };

        let (second_incidents, second_disconnected) = count_events(&mut events);
        assert_eq!(second_incidents, 0);
        assert_eq!(second_disconnected, 0);
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn refresh_and_forwarded_disconnect_race_still_emit_one_incident() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!("temp");
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!("start");
        };
        let active = {
            let Ok(sessions) = manager.state.sessions.lock() else {
                unreachable!("sessions lock");
            };
            let Some(session) = sessions.get(&snapshot.acp_id) else {
                unreachable!("active session");
            };
            Arc::downgrade(session)
        };

        let _ = count_events(&mut events);
        let Ok(lifecycle) = manager.state.process_lifecycle.lock() else {
            unreachable!("process lifecycle lock");
        };
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

        let Ok(refresh_result) = refresh.join() else {
            unreachable!("refresh thread");
        };
        let Ok(_) = refresh_result else {
            unreachable!("refresh snapshot");
        };
        let Ok(disconnect_result) = disconnect.join() else {
            unreachable!("disconnect thread");
        };
        let Ok(()) = disconnect_result else {
            unreachable!("forwarded disconnect");
        };

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
        let Ok(temp) = TempDir::new() else {
            unreachable!("temp");
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, _events) = manager_with_events();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!("start");
        };
        let active = {
            let Ok(sessions) = manager.state.sessions.lock() else {
                unreachable!("sessions lock");
            };
            let Some(session) = sessions.get(&snapshot.acp_id) else {
                unreachable!("active session");
            };
            Arc::clone(session)
        };
        let process = active.process();

        active.poison_permission_bridge_pending_lock_for_test();

        let Ok(refreshed) = manager.get(&snapshot.acp_id) else {
            unreachable!("refresh with poisoned permissions");
        };
        assert_eq!(refreshed.status, AgentStatus::Active);

        let Ok(stopped) = manager.stop(&snapshot.acp_id) else {
            unreachable!("stop after poison");
        };
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
