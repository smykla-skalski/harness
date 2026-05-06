use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::agents::runtime::signal::read_acknowledgments as read_signal_acknowledgments;
use crate::agents::runtime::signal::{
    DeliveryConfig, Signal, SignalPayload, SignalPriority, write_signal_file,
};
use crate::daemon::agent_acp::manager::test_support::{
    seeded_manager, seeded_manager_with_events, write_executable, write_sleeping_acp_agent,
};
use crate::daemon::agent_acp::permission_bridge::DEFAULT_PERMISSION_CAP;
use crate::session::types::ManagedAgentRef;

fn manager() -> AcpAgentManagerHandle {
    seeded_manager()
}

fn with_acp_test_env(temp: &TempDir, action: impl FnOnce()) {
    with_isolated_harness_env(temp.path(), || {
        temp_env::with_var(feature_flags::ACP_ENV, Some("1"), action);
    });
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

fn archive_session_state(manager: &AcpAgentManagerHandle, session_id: &str) {
    let mut state = load_session_state(manager, session_id);
    state.archived_at = Some("2026-05-05T19:15:30Z".into());
    let Some(db) = manager.state.db.get().map(Arc::clone) else {
        unreachable!();
    };
    let Ok(db) = db.lock() else {
        unreachable!();
    };
    let Ok(()) = db.sync_session("project-abc123", &state) else {
        unreachable!();
    };
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
    signal_dir: &Path,
    signal_id: &str,
) -> crate::agents::runtime::signal::SignalAck {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let Ok(acks) = read_signal_acknowledgments(signal_dir) else {
            unreachable!();
        };
        if let Some(ack) = acks.into_iter().find(|ack| ack.signal_id == signal_id) {
            return ack;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for signal ack {signal_id} at {}; entries: {}",
            signal_dir.display(),
            signal_dir_entries(signal_dir)
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn signal_dir_entries(signal_dir: &Path) -> String {
    let mut entries = Vec::new();
    for child in ["pending", "acknowledged"] {
        let dir = signal_dir.join(child);
        let read_dir = match fs_err::read_dir(&dir) {
            Ok(read_dir) => read_dir,
            Err(error) => {
                entries.push(format!("{child}=<{:?}>", error.kind()));
                continue;
            }
        };
        let names = read_dir
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect::<Vec<_>>()
            .join(",");
        entries.push(format!("{child}=[{names}]"));
    }
    entries.join(" ")
}

fn assert_no_signal_ack_within(signal_dir: &Path, signal_id: &str, duration: Duration) {
    let deadline = Instant::now() + duration;
    loop {
        let Ok(acks) = read_signal_acknowledgments(signal_dir) else {
            unreachable!();
        };
        assert!(
            acks.into_iter().all(|ack| ack.signal_id != signal_id),
            "unexpected signal ack {signal_id} in {}",
            signal_dir.display()
        );
        if Instant::now() >= deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[track_caller]
fn assert_signal_pending(signal_dir: &Path, signal_id: &str) {
    let pending = signal_dir.join("pending").join(format!("{signal_id}.json"));
    assert!(
        pending.is_file(),
        "expected pending signal {signal_id} at {}; entries: {}",
        signal_dir.display(),
        signal_dir_entries(signal_dir)
    );
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
        context_root: crate::workspace::project_context_dir(project_dir),
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
        expires_at: "2099-05-05T08:00:00Z".into(),
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
            idempotency_key: Some(format!(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc:gemini:{signal_id}"
            )),
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
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };

        let Ok(listed) = manager.list("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc") else {
            unreachable!();
        };
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].acp_id, snapshot.acp_id);

        let Ok(inspected) = manager.inspect(Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")) else {
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
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
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
async fn stop_session_acp_agents_disconnects_archived_session_agents() {
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
        let Ok(snapshot) = manager.start_descriptor(
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            &request,
            &descriptor,
        ) else {
            unreachable!();
        };
        archive_session_state(&manager, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");

        let Ok(stopped) = manager.stop_session_acp_agents("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        else {
            unreachable!();
        };

        assert_eq!(stopped.len(), 1);
        assert_eq!(stopped[0].acp_id, snapshot.acp_id);
        assert!(matches!(
            stopped[0].status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));
        let Ok(listed) = manager.list("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc") else {
            unreachable!();
        };
        assert!(listed.is_empty());
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

                let Err(error) = manager().start("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", &request)
                else {
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
mod process_keys;
mod runtime_session_rebinding;
mod visibility_cleanup;
