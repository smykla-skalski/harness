use std::io;
use std::path::PathBuf;
use std::process::Child;
use std::sync::Arc;
use std::time::Duration;

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, Implementation, InitializeRequest, InitializeResponse,
    NewSessionResponse, PromptRequest, ResumeSessionResponse, SessionId, TextContent,
};
use agent_client_protocol::{
    Agent, ByteStreams, ConnectionTo, Error as AcpError, ErrorCode, Result as AcpResult,
};
use tokio::process::{ChildStdin, ChildStdout};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tokio::time::timeout;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

use self::handlers::{ClientHandlers, connect_with_client_handlers};
use self::runtime_helpers::report_protocol_result;
use self::session_start::{RuntimeSessionStart, initialize_and_bind_runtime_session};
use crate::agents::acp::batcher::{RoutedSessionNotification, spawn_notification_batcher};
use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::connection::{ConnectionConfig, EventBatch, SupervisorEventSink};
use crate::agents::acp::permission::PermissionMode;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::agents::kind::DisconnectReason;
use crate::daemon::agent_acp::prompt_gate::PromptLease;
use crate::hooks::runner_policy::managed_cluster_binaries;

use super::manager::{AcpAgentManagerHandle, AcpAgentStartRequest};
use super::spawn_credential::{SpawnCredential, release_after_initialization};
mod commands;
mod context;
mod handlers;
mod handshake;
mod lifecycle;
mod runtime_helpers;
mod session_config;
mod session_guard;
mod session_inputs;
mod session_start;
mod session_state;
pub(super) use commands::AcpProtocolHandle;
use commands::{ProtocolCommand, run_protocol_command_loop};
use context::ProtocolContext;
use handshake::harness_client_capabilities;
pub(super) use session_config::AcpSessionRequestConfig;
use session_config::{advertised_session_configuration, apply_requested_session_configuration};
use session_guard::SessionRouteGuard;
const ACP_DEADLINE_EXCEEDED: i32 = -32090;
const SESSION_ROUTE_DRAIN_GRACE: Duration = Duration::from_millis(75);
pub(super) struct SpawnedAcpProtocol {
    pub(super) events: mpsc::Receiver<EventBatch>,
    pub(super) disconnects: mpsc::Receiver<DisconnectReason>,
    pub(super) protocol: JoinHandle<()>,
    pub(super) batcher: JoinHandle<()>,
    pub(super) handle: AcpProtocolHandle,
    pub(super) start: oneshot::Sender<()>,
}

pub(super) struct SpawnProtocolInput<'a> {
    pub request: &'a AcpAgentStartRequest,
    pub session_config: AcpSessionRequestConfig,
    /// A prior agent session to pick up instead of opening a new one.
    pub resume_session_id: Option<String>,
    pub acp_id: &'a str,
    pub session_id: &'a str,
    pub agent_name: String,
    pub runtime_name: String,
    pub project_dir: PathBuf,
    pub supervisor: &'a Arc<AcpSessionSupervisor>,
    pub permission_mode: PermissionMode,
    pub initial_prompt_lease: Option<PromptLease>,
    pub manager: AcpAgentManagerHandle,
    pub credential: Option<SpawnCredential>,
}

pub(super) fn spawn_protocol_task(
    child: &mut Child,
    input: SpawnProtocolInput<'_>,
) -> io::Result<SpawnedAcpProtocol> {
    let SpawnProtocolInput {
        request,
        session_config,
        resume_session_id,
        acp_id,
        session_id,
        agent_name,
        runtime_name,
        project_dir,
        supervisor,
        permission_mode,
        initial_prompt_lease,
        manager,
        credential,
    } = input;
    let stdin = child
        .stdin
        .take()
        .expect("child stdin not captured; spawn with Stdio::piped()");
    let stdout = child
        .stdout
        .take()
        .expect("child stdout not captured; spawn with Stdio::piped()");
    let stdin = ChildStdin::from_std(stdin)?;
    let stdout = ChildStdout::from_std(stdout)?;

    let batcher = spawn_notification_batcher(
        agent_name.clone(),
        Arc::clone(supervisor),
        ConnectionConfig::default(),
    );
    let event_sink = Arc::new(SupervisorEventSink::new(
        batcher.event_sender.clone(),
        acp_id.to_string(),
        agent_name,
        session_id.to_string(),
    ));
    supervisor.attach_event_emitter(Arc::clone(&event_sink) as _);
    let client = Arc::new(
        HarnessAcpClient::new(
            project_dir.clone(),
            project_dir.clone(),
            None,
            managed_cluster_binaries(),
            permission_mode,
        )
        .with_event_sink(Arc::clone(&event_sink)),
    );
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let (disconnect_tx, disconnects) = mpsc::channel(1);
    let (start_tx, start_rx) = oneshot::channel();
    let protocol_task = tokio::spawn(run_protocol(RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt: request.prompt.clone(),
        session_config,
        resume_session_id,
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        runtime_name,
        notifications: batcher.notifications,
        client,
        supervisor: Arc::clone(supervisor),
        initial_prompt_lease,
        cancel_rx,
        command_rx,
        disconnect_tx,
        start_rx,
        manager,
        credential,
    }));
    Ok(SpawnedAcpProtocol {
        events: batcher.events,
        disconnects,
        protocol: protocol_task,
        batcher: batcher.task,
        // One budget covers every command, including the prompt one: a prompt
        // is spawned rather than awaited, so its caller waits for the
        // `session/new` ahead of it and not for the model. The prompt's own
        // 10-minute budget applies inside that spawned task.
        handle: AcpProtocolHandle::new(
            cancel_tx,
            command_tx,
            commands::response_timeout_for(supervisor.config().lifecycle_timeout),
        ),
        start: start_tx,
    })
}

struct RunProtocolArgs {
    stdin: ChildStdin,
    stdout: ChildStdout,
    project_dir: PathBuf,
    prompt: Option<String>,
    session_config: AcpSessionRequestConfig,
    resume_session_id: Option<String>,
    acp_id: String,
    session_id: String,
    runtime_name: String,
    notifications: mpsc::Sender<RoutedSessionNotification>,
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
    initial_prompt_lease: Option<PromptLease>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    command_rx: mpsc::UnboundedReceiver<ProtocolCommand>,
    disconnect_tx: mpsc::Sender<DisconnectReason>,
    start_rx: oneshot::Receiver<()>,
    manager: AcpAgentManagerHandle,
    credential: Option<SpawnCredential>,
}

async fn run_protocol(args: RunProtocolArgs) {
    let RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt,
        session_config,
        resume_session_id,
        acp_id,
        session_id,
        runtime_name,
        notifications,
        client,
        supervisor,
        initial_prompt_lease,
        cancel_rx,
        command_rx,
        disconnect_tx,
        start_rx,
        manager,
        credential,
    } = args;
    if start_rx.await.is_err() {
        return;
    }
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let session_guard = Arc::new(SessionRouteGuard::default());
    let context = ProtocolContext::new(client, Arc::clone(&supervisor), Arc::clone(&session_guard));
    let handlers = ClientHandlers {
        context,
        session_guard: Arc::clone(&session_guard),
        supervisor: Arc::clone(&supervisor),
        manager: manager.clone(),
        notifications,
    };
    let result = connect_with_client_handlers(transport, handlers, async move |connection| {
        run_connection(RunConnectionArgs {
            connection,
            project_dir,
            prompt,
            session_config,
            resume_session_id,
            acp_id,
            session_id,
            runtime_name,
            supervisor,
            initial_prompt_lease,
            cancel_rx,
            command_rx,
            session_guard,
            manager,
            credential,
        })
        .await
    })
    .await;
    report_protocol_result(result, disconnect_tx).await;
}

async fn run_connection(args: RunConnectionArgs) -> AcpResult<()> {
    let RunConnectionArgs {
        connection,
        project_dir,
        prompt,
        session_config,
        resume_session_id,
        acp_id,
        session_id,
        runtime_name,
        supervisor,
        mut initial_prompt_lease,
        mut cancel_rx,
        mut command_rx,
        session_guard,
        manager,
        credential,
    } = args;
    let prompt_timeout = supervisor.config().prompt_timeout;
    // The route is registered inside `initialize_and_bind_runtime_session` between the
    // runtime's `new_session` response and the orchestration bind, so notifications fired
    // by the runtime during the bind window land on the route guard instead of being
    // dropped with `routing_not_initialized`.
    let initialization = initialize_and_bind_runtime_session(RuntimeSessionStart {
        manager: &manager,
        supervisor: &supervisor,
        connection: &connection,
        project_dir,
        session_config: &session_config,
        resume_session_id: resume_session_id.as_deref(),
        session_id: &session_id,
        acp_id: &acp_id,
        runtime_name: &runtime_name,
        session_guard: &session_guard,
    })
    .await;
    let started_session = release_after_initialization(initialization, credential)?;
    let acp_session_id = started_session.session_id.clone();
    let run_result = async {
        apply_requested_session_configuration(
            &supervisor,
            &connection,
            &acp_session_id,
            &session_config,
            advertised_session_configuration(started_session.config_options.as_deref()),
        )
        .await?;
        if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
            let cancelled = send_prompt_or_cancel(
                &supervisor,
                &connection,
                &mut cancel_rx,
                acp_session_id.clone(),
                prompt_timeout,
                prompt,
            )
            .await?;
            drop(initial_prompt_lease.take());
            if cancelled {
                return Ok(());
            }
        }
        run_protocol_command_loop(
            Arc::clone(&supervisor),
            &connection,
            &mut cancel_rx,
            &mut command_rx,
            &session_guard,
            acp_session_id.clone(),
            prompt_timeout,
        )
        .await
    }
    .await;
    if run_result.is_err() {
        let _ = send_cancel_notification(&connection, acp_session_id.clone());
    }
    // Keep route validation active for a short grace window after we have
    // requested cancel so in-flight notifications are not immediately marked
    // stale while transport shutdown is still propagating.
    sleep(SESSION_ROUTE_DRAIN_GRACE).await;
    session_guard.stop_session(&acp_session_id);
    drop(initial_prompt_lease);
    run_result
}

struct RunConnectionArgs {
    connection: ConnectionTo<Agent>,
    project_dir: PathBuf,
    prompt: Option<String>,
    session_config: AcpSessionRequestConfig,
    resume_session_id: Option<String>,
    acp_id: String,
    session_id: String,
    runtime_name: String,
    supervisor: Arc<AcpSessionSupervisor>,
    initial_prompt_lease: Option<PromptLease>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    command_rx: mpsc::UnboundedReceiver<ProtocolCommand>,
    session_guard: Arc<SessionRouteGuard>,
    manager: AcpAgentManagerHandle,
    credential: Option<SpawnCredential>,
}

async fn send_initialize(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    initialize_timeout: Duration,
) -> AcpResult<InitializeResponse> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/initialize"));
    let request = InitializeRequest::new(ProtocolVersion::V1)
        .client_capabilities(harness_client_capabilities())
        .client_info(Implementation::new("harness", env!("CARGO_PKG_VERSION")));
    timeout(
        initialize_timeout,
        connection.send_request(request).block_task(),
    )
    .await
    .map_err(|_| deadline_error("session/initialize", initialize_timeout))?
}

async fn send_new_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
    session_config: &AcpSessionRequestConfig,
) -> AcpResult<NewSessionResponse> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/new"));
    let request =
        session_inputs::new_session_request(project_dir, session_config, supervisor.handshake());
    let budget = supervisor.config().lifecycle_timeout;
    timeout(budget, connection.send_request(request).block_task())
        .await
        .map_err(|_| deadline_error("session/new", budget))?
}

async fn send_resume_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
    session_config: &AcpSessionRequestConfig,
    resume_session_id: &str,
) -> AcpResult<ResumeSessionResponse> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/resume"));
    let request = session_inputs::resume_session_request(
        SessionId::new(resume_session_id.to_string()),
        project_dir,
        session_config,
        supervisor.handshake(),
    );
    let budget = supervisor.config().lifecycle_timeout;
    timeout(budget, connection.send_request(request).block_task())
        .await
        .map_err(|_| deadline_error("session/resume", budget))?
}

async fn send_prompt_or_cancel(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    cancel_rx: &mut mpsc::UnboundedReceiver<()>,
    session_id: SessionId,
    prompt_timeout: Duration,
    prompt: String,
) -> AcpResult<bool> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/prompt"));
    let request = PromptRequest::new(
        session_id.clone(),
        vec![ContentBlock::Text(TextContent::new(prompt))],
    );
    let mut prompt = Box::pin(connection.send_request(request).block_task());
    tokio::select! {
        result = timeout(prompt_timeout, &mut prompt) => {
            let response = result.map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
            session_state::record_stop_reason(supervisor, &response);
            Ok(false)
        }
        Some(()) = cancel_rx.recv() => {
            send_cancel_notification(connection, session_id)?;
            let response = timeout(prompt_timeout, prompt)
                .await
                .map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
            session_state::record_stop_reason(supervisor, &response);
            Ok(true)
        }
    }
}

fn deadline_error(operation: &str, timeout_duration: Duration) -> AcpError {
    AcpError::new(
        ACP_DEADLINE_EXCEEDED,
        format!(
            "ACP {operation} timed out after {} ms",
            timeout_duration.as_millis()
        ),
    )
}

fn send_cancel_notification(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> AcpResult<()> {
    connection.send_notification(CancelNotification::new(session_id))
}

#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;
