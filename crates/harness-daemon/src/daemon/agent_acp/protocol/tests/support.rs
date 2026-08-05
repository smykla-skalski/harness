use super::*;
use crate::daemon::db::prelude::*;

/// `std::process::Child` has no `Drop`, so a placeholder supervisor process
/// would outlive a test that returns early or panics. Harness structs hold this
/// guard as a field rather than implementing `Drop` themselves, because tests
/// routinely move other fields out of those harnesses and Rust forbids partial
/// moves out of a `Drop` type.
pub(super) struct ChildGuard(pub(super) std::process::Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[track_caller]
pub(super) fn ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    let Ok(value) = result else {
        unreachable!("{context}");
    };
    value
}

#[track_caller]
pub(super) fn some<T>(value: Option<T>, context: &str) -> T {
    assert!(value.is_some(), "{context}: unexpected None");
    let Some(value) = value else {
        unreachable!("{context}");
    };
    value
}

/// Waits for the agent to record `count` operations.
///
/// Sleeping a fixed span before cancelling only works if the protocol task got
/// scheduled inside it, which a loaded host does not guarantee: the wall clock
/// runs out whether or not the agent did any work. Use [`session_established`]
/// instead when the agent under test records nothing during startup.
pub(in crate::daemon::agent_acp::protocol) async fn recorded_operations(
    operations: &Mutex<Vec<String>>,
    count: usize,
) {
    settles(&format!("{count} recorded operations"), || {
        operations.lock().expect("recorded operations").len() >= count
    })
    .await;
}

/// Waits for the connection to finish `session/new`.
///
/// The barrier for an agent that records no operation of its own: a test that
/// only needs the connection to be live cannot count operations that never come.
pub(super) async fn session_established(supervisor: &AcpSessionSupervisor) {
    settles("an established session", || {
        supervisor.session_state().is_some()
    })
    .await;
}

async fn settles(label: &str, mut reached: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + LIVENESS;
    while !reached() {
        assert!(
            std::time::Instant::now() < deadline,
            "the protocol never reached {label}"
        );
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

pub(super) fn protocol_manager(
    runtime_name: &str,
    acp_id: &str,
    session_id: &str,
) -> AcpAgentManagerHandle {
    let (sender, _) = broadcast::channel(8);
    let db = ok(DaemonDb::open_in_memory(), "open db");
    let db = crate::daemon::db_handle::DaemonDbOwnedHandle(db);
    let project = DiscoveredProject {
        project_id: "project-protocol".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-protocol".into(),
        checkout_name: "main".into(),
        context_root: "/tmp/data/projects/project-protocol".into(),
        is_worktree: false,
        worktree_name: None,
    };
    ok(db.sync_project(&project), "sync project");
    let now = "2026-04-30T12:00:00Z";
    let mut state =
        session_service::build_new_session("protocol", "protocol", session_id, "claude", None, now);
    ok(
        session_service::apply_join_session(
            &mut state,
            "Protocol ACP",
            runtime_name,
            SessionRole::Worker,
            &[],
            None,
            now,
            None,
            Some(ManagedAgentRef::acp(acp_id)),
        ),
        "register ACP agent",
    );
    ok(db.sync_session(&project.project_id, &state), "sync session");
    let db = Arc::new(Mutex::new(db));
    let db_slot = Arc::new(OnceLock::new());
    assert!(
        db_slot.set(Arc::clone(&db)).is_ok(),
        "seed protocol test db"
    );
    AcpAgentManagerHandle::new(sender, db_slot)
}

pub(super) fn descriptor_with_session_configuration(
    session_configuration: AcpSessionConfiguration,
) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "test-acp".to_string(),
        display_name: "Test ACP".to_string(),
        capabilities: Vec::new(),
        launch_command: "test-acp".to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: crate::agents::acp::catalog::AcpSpawnConfiguration::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration,
        doctor_probe: DoctorProbe {
            command: "test-acp".to_string(),
            args: vec!["--version".to_string()],
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: false,
    }
}

pub(super) fn disabled_session_config() -> AcpSessionRequestConfig {
    AcpSessionRequestConfig::from_request(
        &AcpAgentStartRequest::default(),
        &descriptor_with_session_configuration(AcpSessionConfiguration::default()),
    )
}

/// One MCP server and one extra root from each source, so a test can tell a
/// dropped descriptor input apart from a dropped per-start one.
pub(super) fn session_config_with_inputs() -> AcpSessionRequestConfig {
    let descriptor = descriptor_with_session_configuration(AcpSessionConfiguration {
        mcp_servers: vec![stdio_mcp_server("descriptor-server")],
        additional_directories: vec!["/work/descriptor".to_string()],
        ..Default::default()
    });
    let request = AcpAgentStartRequest {
        mcp_servers: vec![stdio_mcp_server("start-server")],
        additional_directories: vec!["/work/start".to_string()],
        ..AcpAgentStartRequest::default()
    };
    AcpSessionRequestConfig::from_request(&request, &descriptor)
}

pub(super) fn stdio_mcp_server(name: &str) -> AcpMcpServer {
    AcpMcpServer::Stdio {
        name: name.to_string(),
        command: "/usr/bin/true".to_string(),
        args: Vec::new(),
        env: Vec::new(),
    }
}
