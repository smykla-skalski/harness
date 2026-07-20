//! Wire tests for the capability-gated session lifecycle commands: an agent
//! that advertises `session/{list,close,delete}` must receive them, and an
//! agent that does not must never see the request at all.

use std::future::Future;
use std::path::PathBuf;

use agent_client_protocol::schema::v1::ListSessionsRequest;

use super::super::commands::ProtocolCommandResult;
use super::super::session_guard::RouteTarget;
use super::agents::{
    run_agent_recording_initialize_contract, run_agent_recording_session_lifecycle,
};
use super::lifecycle_agents::{
    run_agent_never_answering_close, run_agent_recording_session_inputs,
    run_agent_recording_session_resume,
};
use super::*;

mod teardown_tests;

type AgentResult = agent_client_protocol::Result<()>;

struct LifecycleHarness {
    command_tx: mpsc::UnboundedSender<ProtocolCommand>,
    cancel_tx: mpsc::UnboundedSender<()>,
    operations: Arc<Mutex<Vec<String>>>,
    supervisor: Arc<AcpSessionSupervisor>,
    protocol_task: tokio::task::JoinHandle<AgentResult>,
    agent_task: tokio::task::JoinHandle<AgentResult>,
    _project: tempfile::TempDir,
    _supervisor_child: ChildGuard,
}

/// Drive `run_connection` against `spawn_agent` and hand back the command
/// channel, so each test only has to describe the lifecycle call it makes.
fn lifecycle_harness<F, Fut>(spawn_agent: F) -> LifecycleHarness
where
    F: FnOnce(Channel, Arc<Mutex<Vec<String>>>) -> Fut,
    Fut: Future<Output = AgentResult> + Send + 'static,
{
    lifecycle_harness_with_config(spawn_agent, disabled_session_config())
}

fn lifecycle_harness_with_config<F, Fut>(
    spawn_agent: F,
    session_config: AcpSessionRequestConfig,
) -> LifecycleHarness
where
    F: FnOnce(Channel, Arc<Mutex<Vec<String>>>) -> Fut,
    Fut: Future<Output = AgentResult> + Send + 'static,
{
    lifecycle_harness_resuming(spawn_agent, session_config, None)
}

fn lifecycle_harness_resuming<F, Fut>(
    spawn_agent: F,
    session_config: AcpSessionRequestConfig,
    resume_session_id: Option<String>,
) -> LifecycleHarness
where
    F: FnOnce(Channel, Arc<Mutex<Vec<String>>>) -> Fut,
    Fut: Future<Output = AgentResult> + Send + 'static,
{
    let project = ok(tempfile::tempdir(), "project tempdir");
    let supervisor_child = ChildGuard(ok(
        Command::new("sleep").arg("60").spawn(),
        "spawn supervisor child",
    ));
    let supervisor = Arc::new(AcpSessionSupervisor::new(
        &supervisor_child.0,
        SupervisionConfig {
            initialize_timeout: Duration::from_secs(1),
            prompt_timeout: Duration::from_secs(1),
            lifecycle_timeout: Duration::from_millis(500),
            ..SupervisionConfig::default()
        },
    ));
    let operations = Arc::new(Mutex::new(Vec::<String>::new()));
    let (client_transport, agent_transport) = Channel::duplex();
    let agent_task = tokio::spawn(spawn_agent(agent_transport, Arc::clone(&operations)));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let project_dir = project.path().to_path_buf();
    let protocol_supervisor = Arc::clone(&supervisor);
    let manager = protocol_manager(
        "fake",
        "agent-acp-1",
        "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e",
    );

    let protocol_task = tokio::spawn(async move {
        Client
            .builder()
            .name("harness-test")
            .connect_with(client_transport, async move |connection| {
                run_connection(RunConnectionArgs {
                    connection,
                    project_dir,
                    prompt: None,
                    session_config,
                    resume_session_id,
                    acp_id: "agent-acp-1".to_string(),
                    session_id: "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e".to_string(),
                    runtime_name: "fake".to_string(),
                    supervisor: protocol_supervisor,
                    initial_prompt_lease: None,
                    cancel_rx,
                    command_rx,
                    session_guard: Arc::new(SessionRouteGuard::default()),
                    manager,
                    credential: None,
                })
                .await
            })
            .await
    });

    LifecycleHarness {
        command_tx,
        cancel_tx,
        operations,
        supervisor,
        protocol_task,
        agent_task,
        _project: project,
        _supervisor_child: supervisor_child,
    }
}

impl LifecycleHarness {
    /// Send one command and wait for its reply on the blocking response channel
    /// the protocol loop answers on.
    async fn dispatch<T, F>(&self, build: F) -> ProtocolCommandResult<T>
    where
        T: Send + 'static,
        F: FnOnce(std::sync::mpsc::SyncSender<ProtocolCommandResult<T>>) -> ProtocolCommand,
    {
        self.await_handshake().await;
        let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
        assert!(self.command_tx.send(build(response_tx)).is_ok());
        ok(
            ok(
                tokio::task::spawn_blocking(move || {
                    response_rx.recv_timeout(Duration::from_secs(2))
                })
                .await,
                "dispatch task should not panic",
            ),
            "command response should arrive",
        )
    }

    /// Block until the connection has recorded the agent's handshake.
    ///
    /// The capability gate reads exactly this value, so waiting on it removes
    /// the race a fixed delay would leave: under load the initialize round trip
    /// can outlast any sleep, and every command would then be refused for a
    /// capability the agent had in fact advertised.
    async fn await_handshake(&self) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while self.supervisor.handshake().is_none() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "agent handshake should be recorded before commands dispatch"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    fn recorded(&self) -> Vec<String> {
        self.operations.lock().expect("recorded operations").clone()
    }

    /// Wait for the agent to record an operation starting with `prefix`.
    async fn await_recorded(&self, prefix: &str) -> String {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(record) = self
                .recorded()
                .into_iter()
                .find(|operation| operation.starts_with(prefix))
            {
                return record;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "agent should record a '{prefix}' operation; got {:?}",
                self.recorded()
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    async fn shutdown(self) {
        assert!(self.cancel_tx.send(()).is_ok());
        let protocol_result = ok(
            ok(
                tokio::time::timeout(Duration::from_secs(2), self.protocol_task).await,
                "protocol should stop after cancel",
            ),
            "protocol task should not panic",
        );
        ok(protocol_result, "protocol should complete cleanly");
        self.agent_task.abort();
        let _ = self.agent_task.await;
    }
}

/// The first session on a process is created by `run_connection` itself rather
/// than by the attach command, so it needs its own proof that the declared
/// inputs reached the agent.
#[tokio::test]
#[cfg(unix)]
async fn primary_session_new_carries_declared_mcp_servers_and_directories() {
    let harness = lifecycle_harness_with_config(
        run_agent_recording_session_inputs,
        session_config_with_inputs(),
    );

    let record = harness.await_recorded("new:").await;

    assert_eq!(
        record, "new:mcp=descriptor-server,start-server:dirs=/work/descriptor,/work/start",
        "the first session on a process must carry the same inputs a later attach does"
    );

    harness.shutdown().await;
}

/// A wedged agent must surface a deadline, not park the caller. Without a
/// bound this call never returns, and on the teardown path it takes the
/// process-lifecycle lock and the daemon shutdown down with it.
#[tokio::test]
#[cfg(unix)]
async fn lifecycle_call_against_a_wedged_agent_fails_on_its_deadline() {
    let harness = lifecycle_harness(run_agent_never_answering_close);

    let result = harness
        .dispatch(|response_tx| ProtocolCommand::CloseSession {
            session_id: SessionId::new("acp-session-7"),
            response_tx,
        })
        .await;

    let Err(message) = result else {
        unreachable!("close must not succeed against an agent that never answers");
    };
    assert!(
        message.contains("timed out"),
        "error should report the deadline; got {message}"
    );
    assert!(
        harness.recorded().contains(&"close:acp-session-7".to_string()),
        "the agent should have received the close before we gave up; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn list_sessions_returns_agent_page_when_capability_advertised() {
    let harness = lifecycle_harness(run_agent_recording_session_lifecycle);

    let request = ListSessionsRequest::new()
        .cwd(Some(PathBuf::from("/work")))
        .cursor(Some("page-1".to_owned()));
    let page = ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::ListSessions {
                request,
                response_tx,
            })
            .await,
        "list should succeed with the capability",
    );

    assert_eq!(page.sessions.len(), 2);
    assert_eq!(page.sessions[0].session_id, "acp-session-1");
    assert_eq!(page.sessions[0].cwd, "/work/one");
    assert_eq!(page.sessions[0].title.as_deref(), Some("First"));
    assert_eq!(
        page.sessions[0].updated_at.as_deref(),
        Some("2026-07-20T00:00:00Z")
    );
    assert_eq!(page.sessions[1].session_id, "acp-session-2");
    assert_eq!(page.sessions[1].title, None);
    assert_eq!(page.next_cursor.as_deref(), Some("page-2"));
    assert!(
        harness
            .recorded()
            .contains(&"list:cwd=/work:cursor=page-1".to_string()),
        "agent should have received the cwd and cursor we sent; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn list_sessions_rejected_without_capability() {
    let harness = lifecycle_harness(run_agent_recording_initialize_contract);

    let result = harness
        .dispatch(|response_tx| ProtocolCommand::ListSessions {
            request: ListSessionsRequest::new(),
            response_tx,
        })
        .await;

    let Err(message) = result else {
        unreachable!("list must be rejected without the capability");
    };
    assert!(
        message.contains("session.list"),
        "error should name the missing capability; got {message}"
    );
    assert!(
        !harness
            .recorded()
            .iter()
            .any(|operation| operation.starts_with("list:")),
        "agent must not receive a list request without the capability"
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn close_session_sends_close_when_capability_advertised() {
    let harness = lifecycle_harness(run_agent_recording_session_lifecycle);

    ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::CloseSession {
                session_id: SessionId::new("acp-session-7"),
                response_tx,
            })
            .await,
        "close should succeed with the capability",
    );

    assert!(
        harness.recorded().contains(&"close:acp-session-7".to_string()),
        "agent should have received the close request; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn delete_session_sends_delete_when_capability_advertised() {
    let harness = lifecycle_harness(run_agent_recording_session_lifecycle);

    ok(
        harness
            .dispatch(|response_tx| ProtocolCommand::DeleteSession {
                session_id: SessionId::new("acp-session-9"),
                response_tx,
            })
            .await,
        "delete should succeed with the capability",
    );

    assert!(
        harness
            .recorded()
            .contains(&"delete:acp-session-9".to_string()),
        "agent should have received the delete request; got {:?}",
        harness.recorded()
    );

    harness.shutdown().await;
}

#[tokio::test]
#[cfg(unix)]
async fn close_and_delete_rejected_without_capability() {
    let harness = lifecycle_harness(run_agent_recording_initialize_contract);

    let close = harness
        .dispatch(|response_tx| ProtocolCommand::CloseSession {
            session_id: SessionId::new("acp-session-1"),
            response_tx,
        })
        .await;
    let Err(close_message) = close else {
        unreachable!("close must be rejected without the capability");
    };
    assert!(
        close_message.contains("session.close"),
        "close error should name the missing capability; got {close_message}"
    );

    let delete = harness
        .dispatch(|response_tx| ProtocolCommand::DeleteSession {
            session_id: SessionId::new("acp-session-1"),
            response_tx,
        })
        .await;
    let Err(delete_message) = delete else {
        unreachable!("delete must be rejected without the capability");
    };
    assert!(
        delete_message.contains("session.delete"),
        "delete error should name the missing capability; got {delete_message}"
    );

    assert!(
        harness.recorded().iter().all(|operation| {
            !operation.starts_with("close:") && !operation.starts_with("delete:")
        }),
        "agent must not receive lifecycle requests without the capability"
    );

    harness.shutdown().await;
}
