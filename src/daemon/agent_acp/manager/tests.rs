use std::fs;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use harness_testkit::with_isolated_harness_env;
use tempfile::TempDir;
use tokio::sync::broadcast;

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    seed_daemon_db_at, seeded_manager, seeded_manager_with_events, write_executable,
    write_sleeping_acp_agent,
};
use crate::daemon::agent_acp::permission_bridge::DEFAULT_PERMISSION_CAP;
use crate::daemon::state;
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

fn load_session_state(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
) -> crate::session::types::SessionState {
    let db = manager.state.db.get().map(Arc::clone).expect("manager db");
    db.lock()
        .expect("manager db lock")
        .load_session_state(session_id)
        .expect("load session state")
        .expect("session present")
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_list_stop_tracks_live_snapshot() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
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
        assert!(inspected.agents[0].agent_id.starts_with("fake-"));
        assert_ne!(inspected.agents[0].watchdog_state, "fired");
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn repeated_session_restarts_keep_runtime_bindings_scoped_to_each_managed_agent() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("fake-agent.sh");
        write_sleeping_acp_agent(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();
        let descriptor = descriptor(&script);

        let first = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start first");
        let first_runtime_session = wait_for_runtime_session_id(&manager, "sess-1", &first.acp_id);

        let stopped = manager.stop(&first.acp_id).expect("stop first");
        assert!(matches!(
            stopped.status,
            AgentStatus::Disconnected {
                reason: DisconnectReason::SessionStopped,
                ..
            }
        ));

        let second = manager
            .start_descriptor("sess-1", &request, &descriptor)
            .expect("start second");
        let second_runtime_session =
            wait_for_runtime_session_id(&manager, "sess-1", &second.acp_id);

        assert_ne!(first.agent_id, second.agent_id);

        let state = load_session_state(&manager, "sess-1");
        let first_agent = state.agents.get(&first.agent_id).expect("first agent");
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

        let second_agent = state.agents.get(&second.agent_id).expect("second agent");
        assert_eq!(
            second_agent.managed_agent,
            Some(ManagedAgentRef::acp(&second.acp_id))
        );
        assert_eq!(
            second_agent.agent_session_id.as_deref(),
            Some(second_runtime_session.as_str())
        );
        assert_eq!(second_agent.status, AgentStatus::Active);

        manager.stop(&second.acp_id).expect("stop second");
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn abnormal_exit_populates_disconnect_reason_and_stderr_tail() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let script = temp.path().join("failing-agent.sh");
        write_executable(&script, "#!/bin/sh\necho boom >&2\nexit 7\n");
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_recording_mode_surfaces_log_path_in_inspect() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_changes_when_permission_mode_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_changes_when_project_root_changes() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
        let root_a = temp.path().join("a");
        let root_b = temp.path().join("b");
        fs::create_dir_all(&root_a).expect("mkdir a");
        fs::create_dir_all(&root_b).expect("mkdir b");
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

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn process_key_stable_for_unlisted_env_drift() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = TempDir::new().expect("temp");
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
    let sandbox = TempDir::new().expect("sandbox");
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
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn start_descriptor_lazily_opens_canonical_db_for_orchestration_registration() {
    let sandbox = TempDir::new().expect("sandbox");
    with_isolated_harness_env(sandbox.path(), || {
        temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
            state::ensure_daemon_dirs().expect("ensure daemon dirs");
            let db_path = state::daemon_root().join("harness.db");
            seed_daemon_db_at(&db_path);

            let script = sandbox.path().join("fake-agent.sh");
            write_sleeping_acp_agent(&script);
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                project_dir: Some(sandbox.path().display().to_string()),
                ..AcpAgentStartRequest::default()
            };
            let descriptor = descriptor(&script);
            let (sender, _) = broadcast::channel(16);
            let manager = AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()));

            let snapshot = manager
                .start_descriptor("sess-1", &request, &descriptor)
                .expect("start with lazy-opened daemon db");

            assert!(
                manager.state.db.get().is_some(),
                "manager should cache opened db"
            );
            let state = load_session_state(&manager, "sess-1");
            let agent = state
                .agents
                .get(&snapshot.agent_id)
                .expect("registered ACP agent");
            assert_eq!(
                agent.managed_agent,
                Some(ManagedAgentRef::acp(&snapshot.acp_id))
            );
            assert_eq!(agent.status, AgentStatus::Active);

            manager.stop(&snapshot.acp_id).expect("stop");
        });
    });
}

mod fault_policy;
