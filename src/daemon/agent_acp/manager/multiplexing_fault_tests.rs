use std::path::Path;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    seeded_manager_with_events, write_exiting_acp_agent,
};
use crate::feature_flags;
use crate::session::types::ManagedAgentRef;

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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_exit_disconnects_every_reused_logical_session() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_exiting_acp_agent(&script, 0.2, 7);
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
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
        assert!(matches!(
            session_managed_agent(&manager, "sess-1", &first.acp_id)
                .expect("persisted first agent")
                .status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));
        assert!(matches!(
            session_managed_agent(&manager, "sess-2", &second.acp_id)
                .expect("persisted second agent")
                .status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));

        let incidents = next_process_incidents(&mut events, 2);
        assert_eq!(incident_session_ids(&incidents), vec!["sess-1", "sess-2"]);
        for incident in incidents {
            assert_eq!(
                incident.payload["affected_logical_session_ids"],
                serde_json::json!(["sess-1", "sess-2"])
            );
        }
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_exit_after_logical_stop_reports_only_remaining_sessions() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_exiting_acp_agent(&script, 0.2, 7);
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
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

fn session_managed_agent(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> Option<crate::session::types::AgentRegistration> {
    let db = manager.state.db.get().cloned().expect("seeded manager db");
    let db = db.lock().expect("seeded manager db lock");
    let state = db
        .load_session_state(session_id)
        .expect("load session state")
        .expect("session present");
    state
        .agents
        .values()
        .find(|agent| agent.managed_agent == Some(ManagedAgentRef::acp(acp_id)))
        .cloned()
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
    next_process_incidents(events, 1)
        .into_iter()
        .next()
        .expect("process incident")
}

fn next_process_incidents(
    events: &mut broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
    expected_count: usize,
) -> Vec<crate::daemon::protocol::StreamEvent> {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut incidents = Vec::new();
    loop {
        if let Ok(event) = events.try_recv()
            && event.event == "acp_process_incident"
        {
            incidents.push(event);
            if incidents.len() == expected_count {
                return incidents;
            }
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for process incident"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn incident_session_ids(events: &[crate::daemon::protocol::StreamEvent]) -> Vec<&str> {
    let mut session_ids = events
        .iter()
        .filter_map(|event| event.session_id.as_deref())
        .collect::<Vec<_>>();
    session_ids.sort_unstable();
    session_ids
}
