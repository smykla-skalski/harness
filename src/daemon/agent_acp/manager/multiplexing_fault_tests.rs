use std::path::Path;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    assert_ok, assert_some, seeded_manager_with_events, write_exiting_acp_agent,
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
        let temp = assert_ok(TempDir::new(), "create temp dir");
        let script = temp.path().join("failing-agent.sh");
        write_exiting_acp_agent(&script, 0.2, 7);
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };

        let first = assert_ok(
            manager.start_descriptor(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &request,
                &descriptor,
            ),
            "start first",
        );
        let second = assert_ok(
            manager.start_descriptor(
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                &request,
                &descriptor,
            ),
            "start second",
        );
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
            assert_ok(manager.get(&second.acp_id), "get sibling")
                .status
                .is_disconnected()
        );
        assert!(matches!(
            assert_some(
                session_managed_agent(
                    &manager,
                    "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                    &first.acp_id
                ),
                "persisted first agent",
            )
            .status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));
        assert!(matches!(
            assert_some(
                session_managed_agent(
                    &manager,
                    "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                    &second.acp_id
                ),
                "persisted second agent",
            )
            .status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::ProcessExited { .. },
                ..
            }
        ));

        let incidents = next_process_incidents(&mut events, 2);
        assert_eq!(
            incident_session_ids(&incidents),
            vec![
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
            ]
        );
        for incident in incidents {
            assert_eq!(
                incident.payload["affected_logical_session_ids"],
                serde_json::json!([
                    "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                    "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"
                ])
            );
        }
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_exit_after_logical_stop_reports_only_remaining_sessions() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = assert_ok(TempDir::new(), "create temp dir");
        let script = temp.path().join("failing-agent.sh");
        write_exiting_acp_agent(&script, 0.2, 7);
        let descriptor = descriptor(&script);
        let (manager, mut events) = manager_with_events();
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };

        let first = assert_ok(
            manager.start_descriptor(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &request,
                &descriptor,
            ),
            "start first",
        );
        let second = assert_ok(
            manager.start_descriptor(
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                &request,
                &descriptor,
            ),
            "start second",
        );
        assert_ok(manager.stop(&first.acp_id), "stop first");

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
            serde_json::json!(["00b4a39f-719e-5418-abe8-eb3ab6ea614d"])
        );
        assert_eq!(process_count(&manager), 0);
    });
}

fn process_count(manager: &AcpAgentManagerHandle) -> usize {
    assert_ok(manager.state.processes.lock(), "ACP processes lock").len()
}

fn session_managed_agent(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> Option<crate::session::types::AgentRegistration> {
    let db = assert_some(manager.state.db.get().cloned(), "seeded manager db");
    let db = assert_ok(db.lock(), "seeded manager db lock");
    let state = assert_some(
        assert_ok(db.load_session_state(session_id), "load session state"),
        "session present",
    );
    state
        .agents
        .values()
        .find(|agent| agent.managed_agent == Some(ManagedAgentRef::acp(acp_id)))
        .cloned()
}

fn wait_until_disconnected(manager: &AcpAgentManagerHandle, acp_id: &str) -> AcpAgentSnapshot {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let snapshot = assert_ok(manager.get(acp_id), "refresh");
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
    assert_some(
        next_process_incidents(events, 1).into_iter().next(),
        "process incident",
    )
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
