use std::path::Path;
use std::time::{Duration, Instant};

use super::*;
use crate::agents::acp::catalog::{self, AcpAgentDescriptor};
use crate::daemon::agent_acp::manager::test_support::{
    assert_err, assert_ok, assert_some, seeded_manager, write_cancel_recording_acp_agent,
    write_exiting_acp_agent, write_prompt_delaying_acp_agent, write_sleeping_acp_agent,
};
use crate::session::types::ManagedAgentRef;
use tempfile::TempDir;

fn manager() -> AcpAgentManagerHandle {
    seeded_manager()
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
        excluded_from_initial_default: false,
    }
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn identical_process_contract_reuses_one_child_for_multiple_logical_sessions() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, request) = shared_fake_runtime();

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

        assert_ne!(first.acp_id, second.acp_id);
        assert_ne!(first.agent_id, second.agent_id);
        assert_eq!(first.process_key, second.process_key);
        assert_eq!(first.pid, second.pid);
        assert_eq!(first.pgid, second.pgid);
        assert_eq!(
            session_managed_agent_id(
                &manager,
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &first.acp_id
            ),
            Some(first.agent_id.clone())
        );
        assert_eq!(
            session_managed_agent_id(
                &manager,
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                &second.acp_id
            ),
            Some(second.agent_id.clone())
        );
        assert!(
            session_runtime_session_id(
                &manager,
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &first.acp_id
            )
            .is_some(),
            "reused ACP registration should persist the runtime session id"
        );
        assert!(
            session_runtime_session_id(
                &manager,
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                &second.acp_id
            )
            .is_some(),
            "reused ACP registration should persist the runtime session id"
        );
        assert_eq!(
            assert_ok(
                manager.list("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
                "list first"
            )
            .len(),
            1
        );
        assert_eq!(
            assert_ok(
                manager.list("00b4a39f-719e-5418-abe8-eb3ab6ea614d"),
                "list second"
            )
            .len(),
            1
        );

        assert_ok(manager.stop(&first.acp_id), "stop first");
        assert_ok(manager.stop(&second.acp_id), "stop second");
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

            assert_ne!(first.process_key, second.process_key);
            assert_ne!(first.pid, second.pid);
            assert_eq!(process_count(&manager), 2);

            assert_ok(manager.stop(&first.acp_id), "stop first");
            assert_ok(manager.stop(&second.acp_id), "stop second");
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
            let temp = assert_ok(TempDir::new(), "create temp dir");
            let script = temp.path().join("failing-agent.sh");
            write_exiting_acp_agent(&script, 0.0, 7);
            let descriptor = descriptor(&script);
            let request = AcpAgentStartRequest {
                agent: "fake".to_string(),
                project_dir: Some(temp.path().display().to_string()),
                ..AcpAgentStartRequest::default()
            };
            let manager = manager();
            let first = assert_ok(
                manager.start_descriptor(
                    "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                    &request,
                    &descriptor,
                ),
                "start first isolated failing session",
            );
            let _ = wait_until_disconnected(&manager, &first.acp_id);
            let error = assert_err(
                manager.start_descriptor(
                    "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                    &request,
                    &descriptor,
                ),
                "canonical process key should be backoff-blocked",
            );
            assert!(
                format!("{error}").contains("backoff"),
                "unexpected error: {error}"
            );
        },
    );
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn stopping_one_reused_process_session_keeps_sibling_live() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, request) = shared_fake_runtime();

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
        let sibling = assert_ok(manager.get(&second.acp_id), "get sibling");
        assert_eq!(first.pid, sibling.pid);
        assert!(
            sibling.status.is_alive(),
            "sibling session should remain live after stopping its peer"
        );

        let stopped_again = assert_ok(manager.stop(&first.acp_id), "stop first again");
        assert!(stopped_again.status.is_disconnected());
        assert!(
            assert_ok(manager.get(&second.acp_id), "get sibling")
                .status
                .is_alive(),
            "sibling session should remain live after idempotent peer stop"
        );

        assert_ok(manager.stop(&second.acp_id), "stop second");
        assert_eq!(process_count(&manager), 0);
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn stopping_reused_session_cancels_only_target_protocol_session() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let temp = assert_ok(TempDir::new(), "create temp dir");
        let script = temp.path().join("cancel-agent.sh");
        let cancel_log = temp.path().join("cancel.log");
        write_cancel_recording_acp_agent(&script, &cancel_log);
        let descriptor = descriptor(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();

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
        let sibling_before_stop = assert_ok(manager.get(&second.acp_id), "get sibling before stop");

        assert_ok(manager.stop(&first.acp_id), "stop first");
        assert_eq!(
            wait_for_cancelled_sessions(&cancel_log, 1),
            vec!["acp-session-1"]
        );
        let sibling_after_stop = assert_ok(manager.get(&second.acp_id), "get sibling after stop");
        assert_sibling_session_state_preserved(&sibling_before_stop, &sibling_after_stop);
        assert_eq!(process_count(&manager), 1);

        assert_ok(manager.stop(&second.acp_id), "stop second");
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
        let temp = assert_ok(TempDir::new(), "create temp dir");
        let script = temp.path().join("prompt-agent.sh");
        write_prompt_delaying_acp_agent(&script, 1.0);
        let descriptor = descriptor(&script);
        let request = AcpAgentStartRequest {
            agent: "fake".to_string(),
            prompt: Some("first".to_string()),
            project_dir: Some(temp.path().display().to_string()),
            ..AcpAgentStartRequest::default()
        };
        let manager = manager();

        let first = assert_ok(
            manager.start_descriptor(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &request,
                &descriptor,
            ),
            "start first",
        );
        let second = manager.start_descriptor(
            "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
            &request,
            &descriptor,
        );
        let error = assert_err(second, "busy prompt should reject second start");

        assert!(error.to_string().contains("prompt_busy"));
        assert_eq!(process_count(&manager), 1);

        assert_ok(manager.stop(&first.acp_id), "stop first");
    });
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn prompted_reuse_attaches_to_idle_shared_process() {
    temp_env::with_var(feature_flags::ACP_ENV, Some("1"), || {
        let (_temp, manager, descriptor, mut request) = shared_fake_runtime();

        let first = assert_ok(
            manager.start_descriptor(
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
                &request,
                &descriptor,
            ),
            "start first",
        );
        request.prompt = Some("next".to_string());
        let second = assert_ok(
            manager.start_descriptor(
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d",
                &request,
                &descriptor,
            ),
            "start prompted second",
        );

        assert_eq!(first.process_key, second.process_key);
        assert_eq!(first.pid, second.pid);
        assert_eq!(process_count(&manager), 1);

        assert_ok(manager.stop(&first.acp_id), "stop first");
        assert_ok(manager.stop(&second.acp_id), "stop second");
    });
}

#[cfg(unix)]
fn shared_fake_runtime() -> (
    TempDir,
    AcpAgentManagerHandle,
    AcpAgentDescriptor,
    AcpAgentStartRequest,
) {
    let temp = assert_ok(TempDir::new(), "create temp dir");
    let script = temp.path().join("fake-agent.sh");
    write_sleeping_acp_agent(&script);
    let descriptor = descriptor(&script);
    let request = AcpAgentStartRequest {
        agent: "fake".to_string(),
        project_dir: Some(temp.path().display().to_string()),
        ..AcpAgentStartRequest::default()
    };
    (temp, manager(), descriptor, request)
}

fn process_count(manager: &AcpAgentManagerHandle) -> usize {
    assert_ok(manager.state.processes.lock(), "ACP processes lock").len()
}

fn session_managed_agent_id(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> Option<String> {
    session_managed_agent(manager, session_id, acp_id).map(|agent| agent.agent_id)
}

fn session_runtime_session_id(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
) -> Option<String> {
    session_managed_agent(manager, session_id, acp_id).and_then(|agent| agent.agent_session_id)
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
    assert!(
        after.status.is_alive(),
        "sibling session should remain live after stopping its peer"
    );
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
