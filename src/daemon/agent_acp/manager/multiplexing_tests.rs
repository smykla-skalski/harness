use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    write_cancel_recording_acp_agent, write_exiting_acp_agent, write_prompt_delaying_acp_agent,
    write_sleeping_acp_agent,
};

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

#[tokio::test(flavor = "multi_thread")]
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn pooling_disable_env_starts_separate_children_for_identical_contracts() {
    temp_env::with_vars(
        [
            (feature_flags::ACP_ENV, Some("1")),
            ("HARNESS_ACP_DISABLE_POOLING", Some("1")),
        ],
        || {
            let (_temp, manager, descriptor, request) = shared_fake_runtime();

            let first = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start first");
            let second = manager
                .start_descriptor("sess-2", &request, &descriptor)
                .expect("start second");

            assert_ne!(first.process_key, second.process_key);
            assert_ne!(first.pid, second.pid);
            assert_eq!(process_count(&manager), 2);

            manager.stop(&first.acp_id).expect("stop first");
            manager.stop(&second.acp_id).expect("stop second");
        },
    );
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn pooling_disabled_faults_still_backoff_canonical_process_key() {
    temp_env::with_vars(
        [
            (feature_flags::ACP_ENV, Some("1")),
            ("HARNESS_ACP_DISABLE_POOLING", Some("1")),
        ],
        || {
            let temp = TempDir::new().expect("temp");
            let script = temp.path().join("failing-agent.sh");
            write_exiting_acp_agent(&script, 0.0, 7);
            let descriptor = descriptor(&script);
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                prompt: None,
                project_dir: Some(temp.path().display().to_string()),
                record_permissions: false,
            };
            let manager = manager();
            let first = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start first isolated failing session");
            let _ = wait_until_disconnected(&manager, &first.acp_id);
            let error = manager
                .start_descriptor("sess-2", &request, &descriptor)
                .expect_err("canonical process key should be backoff-blocked");
            assert!(
                format!("{error}").contains("backoff"),
                "unexpected error: {error}"
            );
        },
    );
}

#[tokio::test(flavor = "multi_thread")]
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn stopping_reused_session_cancels_only_target_protocol_session() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("cancel-agent.sh");
        let cancel_log = temp.path().join("cancel.log");
        write_cancel_recording_acp_agent(&script, &cancel_log);
        let descriptor = descriptor(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: None,
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };
        let manager = manager();

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start second");
        let sibling_before_stop = manager
            .get(&second.acp_id)
            .expect("get sibling before stop");

        manager.stop(&first.acp_id).expect("stop first");
        assert_eq!(
            wait_for_cancelled_sessions(&cancel_log, 1),
            vec!["acp-session-1"]
        );
        let sibling_after_stop = manager.get(&second.acp_id).expect("get sibling after stop");
        assert_sibling_session_state_preserved(&sibling_before_stop, &sibling_after_stop);
        assert_eq!(process_count(&manager), 1);

        manager.stop(&second.acp_id).expect("stop second");
        assert_eq!(
            wait_for_cancelled_sessions(&cancel_log, 2),
            vec!["acp-session-1", "acp-session-2"]
        );
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn prompted_reuse_rejects_busy_prompt_without_saturation_spawn() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("prompt-agent.sh");
        write_prompt_delaying_acp_agent(&script, 1.0);
        let descriptor = descriptor(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: Some("first".to_string()),
            project_dir: Some(temp.path().display().to_string()),
            record_permissions: false,
        };
        let manager = manager();

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let second = manager.start_descriptor("sess-2", &request, &descriptor);

        assert!(
            second
                .expect_err("busy prompt should reject second start")
                .to_string()
                .contains("prompt_busy")
        );
        assert_eq!(process_count(&manager), 1);

        manager.stop(&first.acp_id).expect("stop first");
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn prompted_reuse_attaches_to_idle_shared_process() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, mut request) = shared_fake_runtime();

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        request.prompt = Some("next".to_string());
        let second = manager
            .start_descriptor("sess-2", &request, &descriptor)
            .expect("start prompted second");

        assert_eq!(first.process_key, second.process_key);
        assert_eq!(first.pid, second.pid);
        assert_eq!(process_count(&manager), 1);

        manager.stop(&first.acp_id).expect("stop first");
        manager.stop(&second.acp_id).expect("stop second");
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
    write_sleeping_acp_agent(&script);
    let descriptor = descriptor(&script);
    let request = AcpAgentStartRequest {
        agent: "fake".to_string(),
        prompt: None,
        project_dir: Some(temp.path().display().to_string()),
        record_permissions: false,
    };
    (temp, manager(), descriptor, request)
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

#[cfg(unix)]
fn wait_for_cancelled_sessions(path: &Path, expected_count: usize) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let sessions = std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        if sessions.len() >= expected_count || Instant::now() >= deadline {
            return sessions;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(unix)]
fn assert_sibling_session_state_preserved(before: &AcpAgentSnapshot, after: &AcpAgentSnapshot) {
    assert_eq!(after.status, AgentStatus::Active);
    assert_eq!(before.acp_id, after.acp_id);
    assert_eq!(before.session_id, after.session_id);
    assert_eq!(before.process_key, after.process_key);
    assert_eq!(before.pid, after.pid);
    assert_eq!(before.pgid, after.pgid);
    assert_eq!(before.permission_mode, after.permission_mode);
    assert_eq!(before.permission_log_path, after.permission_log_path);
    assert_eq!(before.pending_permissions, after.pending_permissions);
    assert_eq!(before.permission_queue_depth, after.permission_queue_depth);
    assert_eq!(
        before.pending_permission_batches,
        after.pending_permission_batches
    );
    assert_eq!(before.terminal_count, after.terminal_count);
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
