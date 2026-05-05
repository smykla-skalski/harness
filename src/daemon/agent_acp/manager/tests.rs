use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::agents::runtime::runtime_for;
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalPayload, SignalPriority, read_pending_signals,
};
use crate::daemon::agent_acp::manager::test_support::{
    seeded_manager, seeded_manager_with_events, write_executable, write_sleeping_acp_agent,
};
use crate::daemon::agent_acp::permission_bridge::DEFAULT_PERMISSION_CAP;
use crate::hooks::adapters::HookAgent;
use crate::session::types::ManagedAgentRef;

fn manager() -> AcpAgentManagerHandle {
    seeded_manager()
}

fn manager_with_events() -> (
    AcpAgentManagerHandle,
    broadcast::Receiver<crate::daemon::protocol::StreamEvent>,
) {
    seeded_manager_with_events()
}

fn descriptor(command: &Path) -> AcpAgentDescriptor {
    descriptor_with_id(command, "fake")
}

fn descriptor_with_id(command: &Path, id: &str) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: id.to_string(),
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
        let Ok(snapshot) = manager.get(acp_id) else {
            unreachable!();
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

fn load_session_state(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
) -> crate::session::types::SessionState {
    let Some(db) = manager.state.db.get().map(Arc::clone) else {
        unreachable!();
    };
    let Ok(db) = db.lock() else {
        unreachable!();
    };
    let Ok(state) = db.load_session_state(session_id) else {
        unreachable!();
    };
    let Some(state) = state else {
        unreachable!();
    };
    state
}

fn runtime_session_id(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> Option<String> {
    load_session_state(manager, session_id)
        .agents
        .values()
        .find(|agent| agent.managed_agent == Some(ManagedAgentRef::acp(acp_id)))
        .and_then(|agent| agent.agent_session_id.clone())
}

fn wait_for_runtime_session_id(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> String {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(agent_session_id) = runtime_session_id(manager, session_id, acp_id) {
            return agent_session_id;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for ACP runtime session binding"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_runtime_session_id_value(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
    expected: &str,
) {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if runtime_session_id(manager, session_id, acp_id).as_deref() == Some(expected) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for ACP runtime session binding to update to {expected}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_signal_ack(
    runtime: &'static dyn crate::agents::runtime::AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
) -> crate::agents::runtime::signal::SignalAck {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let Ok(acks) = runtime.read_acknowledgments(project_dir, signal_session_id) else {
            unreachable!();
        };
        if let Some(ack) = acks.into_iter().find(|ack| ack.signal_id == signal_id) {
            return ack;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for signal ack {signal_id} in {signal_session_id}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn assert_no_signal_ack_within(
    runtime: &'static dyn crate::agents::runtime::AgentRuntime,
    project_dir: &Path,
    signal_session_id: &str,
    signal_id: &str,
    duration: Duration,
) {
    let deadline = Instant::now() + duration;
    loop {
        let Ok(acks) = runtime.read_acknowledgments(project_dir, signal_session_id) else {
            unreachable!();
        };
        assert!(
            acks.into_iter().all(|ack| ack.signal_id != signal_id),
            "unexpected signal ack {signal_id} in {signal_session_id}"
        );
        if Instant::now() >= deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn repoint_project_dir(manager: &AcpAgentManagerHandle, project_dir: &Path) {
    let Some(db) = manager.state.db.get().map(Arc::clone) else {
        unreachable!();
    };
    let Ok(db) = db.lock() else {
        unreachable!();
    };
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-abc123".into(),
        name: "harness".into(),
        project_dir: Some(project_dir.to_path_buf()),
        repository_root: Some(project_dir.to_path_buf()),
        checkout_id: "checkout-abc123".into(),
        checkout_name: "Repository".into(),
        context_root: project_dir.to_path_buf(),
        is_worktree: false,
        worktree_name: None,
    };
    let Ok(()) = db.sync_project(&project) else {
        unreachable!();
    };
}

fn sample_signal(signal_id: &str) -> Signal {
    Signal {
        signal_id: signal_id.to_string(),
        version: 1,
        created_at: "2026-05-05T07:00:00Z".into(),
        expires_at: "2026-05-05T08:00:00Z".into(),
        source_agent: "claude-leader".into(),
        command: "task.start".into(),
        priority: SignalPriority::Normal,
        payload: SignalPayload {
            message: "Start work on task task-1: investigate".into(),
            action_hint: Some("task:task-1".into()),
            related_files: Vec::new(),
            metadata: json!({}),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: Some(format!("sess-1:gemini:{signal_id}")),
        },
    }
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_list_stop_tracks_live_snapshot() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };

        let Ok(listed) = manager.list("sess-1") else {
            unreachable!();
        };
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].acp_id, snapshot.acp_id);

        let Ok(inspected) = manager.inspect(Some("sess-1")) else {
            unreachable!();
        };
        assert_eq!(inspected.agents.len(), 1);
        assert_eq!(inspected.agents[0].acp_id, snapshot.acp_id);
        assert!(inspected.agents[0].agent_id.starts_with("fake-"));
        assert_ne!(inspected.agents[0].watchdog_state, "fired");
        assert_eq!(inspected.agents[0].permission_mode, "daemon_bridge");
        assert_eq!(inspected.agents[0].permission_queue_depth, 0);
        assert_eq!(inspected.agents[0].permission_log_path, None);
        assert!(!inspected.agents[0].process_key.is_empty());

        let Ok(stopped) = manager.stop(&snapshot.acp_id) else {
            unreachable!();
        };
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn repeated_session_restarts_keep_runtime_bindings_scoped_to_each_managed_agent() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);

        let Ok(first) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };
        let first_runtime_session = wait_for_runtime_session_id(&manager, "sess-1", &first.acp_id);

        let Ok(stopped) = manager.stop(&first.acp_id) else {
            unreachable!();
        };
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));

        let Ok(second) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };
        let second_runtime_session =
            wait_for_runtime_session_id(&manager, "sess-1", &second.acp_id);

        assert_ne!(first.agent_id, second.agent_id);

        let state = load_session_state(&manager, "sess-1");
        let Some(first_agent) = state.agents.get(&first.agent_id) else {
            unreachable!();
        };
        assert_eq!(
            first_agent.managed_agent,
            Some(ManagedAgentRef::acp(&first.acp_id))
        );
        assert_eq!(
            first_agent.agent_session_id.as_deref(),
            Some(first_runtime_session.as_str())
        );
        assert!(matches!(
            first_agent.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));

        let Some(second_agent) = state.agents.get(&second.agent_id) else {
            unreachable!();
        };
        assert_eq!(
            second_agent.managed_agent,
            Some(ManagedAgentRef::acp(&second.acp_id))
        );
        assert_eq!(
            second_agent.agent_session_id.as_deref(),
            Some(second_runtime_session.as_str())
        );
        assert_eq!(second_agent.status, AgentStatus::Active);

        assert!(manager.stop(&second.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_rebinds_runtime_session_when_prompt_opens_new_protocol_session() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };
        let initial_runtime_session =
            wait_for_runtime_session_id(&manager, "sess-1", &snapshot.acp_id);
        assert_eq!(initial_runtime_session, "acp-session-1");

        manager.dispatch_wake_prompt(
            runtime_for(HookAgent::Gemini),
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "sess-1".into(),
                signal_session_id: initial_runtime_session,
                project_dir: temp.path().to_path_buf(),
                prompt: "tell me how are you".into(),
                signal_id: "sig-test-1".into(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        wait_for_runtime_session_id_value(&manager, "sess-1", &snapshot.acp_id, "acp-session-2");
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_acknowledges_signal_in_original_signal_session_dir() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };
        let runtime = runtime_for(HookAgent::Gemini);
        let signal_session_id = wait_for_runtime_session_id(&manager, "sess-1", &snapshot.acp_id);
        let signal = sample_signal("sig-ack-success");
        let Ok(_path) = runtime.write_signal(temp.path(), &signal_session_id, &signal) else {
            unreachable!();
        };

        manager.dispatch_wake_prompt(
            runtime,
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "sess-1".into(),
                signal_session_id: signal_session_id.clone(),
                project_dir: temp.path().to_path_buf(),
                prompt: "please wake up".into(),
                signal_id: signal.signal_id.clone(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        wait_for_runtime_session_id_value(&manager, "sess-1", &snapshot.acp_id, "acp-session-2");
        let ack = wait_for_signal_ack(runtime, temp.path(), &signal_session_id, &signal.signal_id);
        assert_eq!(ack.result, AckResult::Accepted);
        assert_eq!(ack.session_id, "sess-1");
        assert_eq!(ack.agent, signal_session_id);

        let signal_dir = runtime.signal_dir(temp.path(), &signal_session_id);
        let Ok(pending) = read_pending_signals(&signal_dir) else {
            unreachable!();
        };
        assert!(pending.is_empty(), "pending signal should have been acknowledged");
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn wake_prompt_skips_ack_when_runtime_rebind_fails() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("gemini-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "gemini".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        repoint_project_dir(&manager, temp.path());
        let descriptor = descriptor_with_id(&script, "gemini");
        let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };
        let runtime = runtime_for(HookAgent::Gemini);
        let signal_session_id = wait_for_runtime_session_id(&manager, "sess-1", &snapshot.acp_id);
        let signal = sample_signal("sig-ack-skipped");
        let Ok(_path) = runtime.write_signal(temp.path(), &signal_session_id, &signal) else {
            unreachable!();
        };

        manager.dispatch_wake_prompt(
            runtime,
            AcpWakePrompt {
                acp_id: snapshot.acp_id.clone(),
                orchestration_session_id: "missing-session".into(),
                signal_session_id: signal_session_id.clone(),
                project_dir: temp.path().to_path_buf(),
                prompt: "please wake up".into(),
                signal_id: signal.signal_id.clone(),
                agent_id: snapshot.agent_id.clone(),
            },
        );

        assert_no_signal_ack_within(
            runtime,
            temp.path(),
            &signal_session_id,
            &signal.signal_id,
            Duration::from_millis(400),
        );
        assert_no_signal_ack_within(
            runtime,
            temp.path(),
            "acp-session-2",
            &signal.signal_id,
            Duration::from_millis(400),
        );

        let signal_dir = runtime.signal_dir(temp.path(), &signal_session_id);
        let Ok(pending) = read_pending_signals(&signal_dir) else {
            unreachable!();
        };
        assert!(
            pending.iter().any(|pending| pending.signal_id == signal.signal_id),
            "pending signal should remain file-backed when runtime rebind fails"
        );
        assert_eq!(
            runtime_session_id(&manager, "sess-1", &snapshot.acp_id).as_deref(),
            Some(signal_session_id.as_str())
        );
        assert!(manager.stop(&snapshot.acp_id).is_ok());
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn abnormal_exit_populates_disconnect_reason_and_stderr_tail() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let Ok(temp) = TempDir::new() else {
            unreachable!();
        };
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\necho boom >&2\nexit 7\n");
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let (manager, mut events) = manager_with_events();
        let descriptor = descriptor(&script);
        let Ok(snapshot) = manager.start_descriptor("sess-1", &request, &descriptor) else {
            unreachable!();
        };

        let deadline = Instant::now() + Duration::from_secs(2);
        let refreshed = loop {
            let Ok(refreshed) = manager.get(&snapshot.acp_id) else {
                unreachable!();
            };
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
            unreachable!();
        };
        assert!(matches!(stderr_tail.as_deref(), Some(tail) if tail.contains("boom")));
        let saw_process_incident = (0..32).any(|_| match events.try_recv() {
            Ok(event) => event.event == "acp_process_incident",
            Err(_) => false,
        });
        assert!(saw_process_incident, "expected acp_process_incident event");
    });
}

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

#[test]
fn default_permission_cap_matches_plan() {
    assert_eq!(DEFAULT_PERMISSION_CAP, 8);
}

#[test]
fn start_rejects_sandboxed_daemon_mode() {
    let Ok(sandbox) = TempDir::new() else {
        unreachable!();
    };
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_vars(
            [
                (feature_flags::ACP_ENV, Some("1")),
                ("HARNESS_SANDBOXED", Some("1")),
            ],
            || {
                let request = AcpAgentStartRequest {
                    agent: "copilot".to_string(),
                    ..AcpAgentStartRequest::default()
                };

                let Err(error) = manager().start("sess-1", &request) else {
                    unreachable!();
                };
                let rendered = format!("{error}");
                assert!(
                    rendered.contains("sandbox feature disabled: acp.host-bridge"),
                    "unexpected error: {rendered}"
                );
            },
        );
    });
}

mod fault_policy;
mod lazy_db;
mod visibility_cleanup;
