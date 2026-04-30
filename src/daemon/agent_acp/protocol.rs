use std::io;
use std::path::PathBuf;
use std::process::Child;
use std::sync::Arc;
use std::time::Duration;

use agent_client_protocol::schema::{
    CancelNotification, ContentBlock, CreateTerminalRequest, InitializeRequest,
    KillTerminalRequest, NewSessionRequest, PromptRequest, ProtocolVersion, ReadTextFileRequest,
    ReleaseTerminalRequest, RequestPermissionRequest, SessionId, SessionNotification,
    TerminalOutputRequest, TextContent, WaitForTerminalExitRequest, WriteTextFileRequest,
};
use agent_client_protocol::{
    Agent, ByteStreams, Client, ConnectionTo, Error as AcpError, ErrorCode, Result as AcpResult,
};
use tokio::process::{ChildStdin, ChildStdout};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tokio::time::timeout;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

use crate::agents::acp::batcher::{RoutedSessionNotification, spawn_notification_batcher};
use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::connection::{ConnectionConfig, EventBatch};
use crate::agents::acp::permission::PermissionMode;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::agents::kind::DisconnectReason;
use crate::daemon::agent_acp::prompt_gate::PromptLease;
use crate::hooks::runner_policy::managed_cluster_binaries;

use super::manager::{AcpAgentManagerHandle, AcpAgentStartRequest};
mod commands;
mod context;
mod session_guard;
pub(super) use commands::AcpProtocolHandle;
use commands::{ProtocolCommand, run_protocol_command_loop};
use context::{ProtocolContext, handle_permission_request, respond_client_result};
use session_guard::{RouteTarget, SessionRouteGuard};
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
    pub acp_id: &'a str,
    pub session_id: &'a str,
    pub agent_name: String,
    pub runtime_name: String,
    pub project_dir: PathBuf,
    pub supervisor: &'a Arc<AcpSessionSupervisor>,
    pub permission_mode: PermissionMode,
    pub initial_prompt_lease: Option<PromptLease>,
    pub manager: AcpAgentManagerHandle,
}

pub(super) fn spawn_protocol_task(
    child: &mut Child,
    input: SpawnProtocolInput<'_>,
) -> io::Result<SpawnedAcpProtocol> {
    let SpawnProtocolInput {
        request,
        acp_id,
        session_id,
        agent_name,
        runtime_name,
        project_dir,
        supervisor,
        permission_mode,
        initial_prompt_lease,
        manager,
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
        agent_name,
        Arc::clone(supervisor),
        ConnectionConfig::default(),
    );
    let client = Arc::new(HarnessAcpClient::new(
        project_dir.clone(),
        project_dir.clone(),
        None,
        managed_cluster_binaries(),
        permission_mode,
    ));
    let (cancel_tx, cancel_rx) = mpsc::unbounded_channel();
    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let (disconnect_tx, disconnects) = mpsc::channel(1);
    let (start_tx, start_rx) = oneshot::channel();
    let protocol_task = tokio::spawn(run_protocol(RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt: request.prompt.clone(),
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
    }));
    Ok(SpawnedAcpProtocol {
        events: batcher.events,
        disconnects,
        protocol: protocol_task,
        batcher: batcher.task,
        handle: AcpProtocolHandle::new(cancel_tx, command_tx),
        start: start_tx,
    })
}

struct RunProtocolArgs {
    stdin: ChildStdin,
    stdout: ChildStdout,
    project_dir: PathBuf,
    prompt: Option<String>,
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
}

#[expect(
    clippy::too_many_lines,
    reason = "ACP protocol builder keeps all request routing in one registration table"
)]
async fn run_protocol(args: RunProtocolArgs) {
    let RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt,
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
    } = args;
    if start_rx.await.is_err() {
        return;
    }
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let session_guard = Arc::new(SessionRouteGuard::default());
    let context = ProtocolContext::new(client, Arc::clone(&supervisor), Arc::clone(&session_guard));
    let notification_guard = Arc::clone(&session_guard);
    let read_context = context.clone();
    let write_context = context.clone();
    let create_terminal_context = context.clone();
    let terminal_output_context = context.clone();
    let release_terminal_context = context.clone();
    let wait_terminal_context = context.clone();
    let kill_terminal_context = context.clone();
    let permission_context = context;
    let result = Client
        .builder()
        .name("harness")
        .on_receive_notification(
            async move |notification: SessionNotification, _connection| {
                route_session_notification(&notification_guard, &notifications, notification).await
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: ReadTextFileRequest, responder, _connection| {
                respond_client_result(responder, read_context.read_text_file(&request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WriteTextFileRequest, responder, _connection| {
                respond_client_result(responder, write_context.write_text_file(&request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: CreateTerminalRequest, responder, _connection| {
                respond_client_result(responder, create_terminal_context.create_terminal(&request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: TerminalOutputRequest, responder, _connection| {
                respond_client_result(responder, terminal_output_context.terminal_output(&request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: ReleaseTerminalRequest, responder, _connection| {
                respond_client_result(
                    responder,
                    release_terminal_context.release_terminal(&request),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WaitForTerminalExitRequest, responder, _connection| {
                respond_client_result(
                    responder,
                    wait_terminal_context.wait_for_terminal_exit(&request),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: KillTerminalRequest, responder, _connection| {
                respond_client_result(responder, kill_terminal_context.kill_terminal(&request))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _connection| {
                handle_permission_request(request, responder, permission_context.clone()).await
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(transport, async move |connection| {
            run_connection(RunConnectionArgs {
                connection,
                project_dir,
                prompt,
                acp_id,
                session_id,
                runtime_name,
                supervisor,
                initial_prompt_lease,
                cancel_rx,
                command_rx,
                session_guard,
                manager,
            })
            .await
        })
        .await;
    report_protocol_result(result, disconnect_tx).await;
}

async fn route_session_notification(
    notification_guard: &SessionRouteGuard,
    notifications: &mpsc::Sender<RoutedSessionNotification>,
    notification: SessionNotification,
) -> AcpResult<()> {
    let Some(routed) = routed_session_notification(notification_guard, notification) else {
        return Ok(());
    };
    notifications
        .send(routed)
        .await
        .map_err(|error| AcpError::new(-32603, format!("queue ACP event: {error}")))?;
    Ok(())
}

fn routed_session_notification(
    notification_guard: &SessionRouteGuard,
    notification: SessionNotification,
) -> Option<RoutedSessionNotification> {
    let target = match notification_guard.ensure_known(&notification.session_id) {
        Ok(target) => target,
        Err(route_error) => {
            log_unroutable_notification(&notification.session_id, route_error.reason.as_str());
            return None;
        }
    };
    Some(RoutedSessionNotification {
        acp_id: target.acp_id,
        session_id: target.session_id,
        notification,
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_unroutable_notification(session_id: &SessionId, reason: &str) {
    tracing::debug!(
        session_id = %session_id,
        reason,
        "dropping unroutable ACP notification"
    );
}

async fn report_protocol_result(
    result: AcpResult<()>,
    disconnect_tx: mpsc::Sender<DisconnectReason>,
) {
    let Err(error) = result else {
        return;
    };
    warn_protocol_error(&error);
    let _ = disconnect_tx
        .send(disconnect_reason_from_error(&error))
        .await;
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_protocol_error(error: &AcpError) {
    tracing::warn!(%error, "ACP protocol task stopped");
}

fn disconnect_reason_from_error(error: &AcpError) -> DisconnectReason {
    if matches!(error.code, ErrorCode::Other(ACP_DEADLINE_EXCEEDED))
        && error.message.contains("session/initialize")
    {
        DisconnectReason::InitializeTimeout
    } else if matches!(error.code, ErrorCode::Other(ACP_DEADLINE_EXCEEDED))
        && error.message.contains("session/prompt")
    {
        DisconnectReason::PromptTimeout
    } else if is_transport_closed_error(error) {
        DisconnectReason::TransportClosed
    } else {
        DisconnectReason::StdioClosed
    }
}

fn is_transport_closed_error(error: &AcpError) -> bool {
    let message = error.message.to_ascii_lowercase();
    message.contains("transport closed")
        || message.contains("connection closed")
        || message.contains("broken pipe")
        || message.contains("unexpected eof")
}

async fn run_connection(args: RunConnectionArgs) -> AcpResult<()> {
    let RunConnectionArgs {
        connection,
        project_dir,
        prompt,
        acp_id,
        session_id,
        runtime_name,
        supervisor,
        mut initial_prompt_lease,
        mut cancel_rx,
        mut command_rx,
        session_guard,
        manager,
    } = args;
    let initialize_timeout = supervisor.config().initialize_timeout;
    let prompt_timeout = supervisor.config().prompt_timeout;

    send_initialize(&connection, initialize_timeout).await?;
    let acp_session_id = send_new_session(&connection, project_dir).await?;
    let registered = manager
        .bind_orchestration_runtime_session(
            &session_id,
            &acp_id,
            &runtime_name,
            &acp_session_id.to_string(),
        )
        .map_err(|error| AcpError::new(-32603, format!("bind ACP runtime session: {error}")))?;
    if !registered {
        return Err(AcpError::new(
            -32603,
            format!("bind ACP runtime session: missing orchestration agent for '{acp_id}'"),
        ));
    }
    let target = RouteTarget { acp_id, session_id };
    session_guard.start_session(&acp_session_id, target.clone());
    let run_result = async {
        if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
            let cancelled = send_prompt_or_cancel(
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
    acp_id: String,
    session_id: String,
    runtime_name: String,
    supervisor: Arc<AcpSessionSupervisor>,
    initial_prompt_lease: Option<PromptLease>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    command_rx: mpsc::UnboundedReceiver<ProtocolCommand>,
    session_guard: Arc<SessionRouteGuard>,
    manager: AcpAgentManagerHandle,
}

async fn send_initialize(
    connection: &ConnectionTo<Agent>,
    initialize_timeout: Duration,
) -> AcpResult<()> {
    timeout(
        initialize_timeout,
        connection
            .send_request(InitializeRequest::new(ProtocolVersion::V1))
            .block_task(),
    )
    .await
    .map_err(|_| deadline_error("session/initialize", initialize_timeout))??;
    Ok(())
}

async fn send_new_session(
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
) -> AcpResult<SessionId> {
    let response = connection
        .send_request(NewSessionRequest::new(project_dir))
        .block_task()
        .await?;
    Ok(response.session_id)
}

async fn send_prompt_or_cancel(
    connection: &ConnectionTo<Agent>,
    cancel_rx: &mut mpsc::UnboundedReceiver<()>,
    session_id: SessionId,
    prompt_timeout: Duration,
    prompt: String,
) -> AcpResult<bool> {
    let request = PromptRequest::new(
        session_id.clone(),
        vec![ContentBlock::Text(TextContent::new(prompt))],
    );
    let mut prompt = Box::pin(connection.send_request(request).block_task());
    tokio::select! {
        result = timeout(prompt_timeout, &mut prompt) => {
            result.map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
            Ok(false)
        }
        Some(()) = cancel_rx.recv() => {
            send_cancel_notification(connection, session_id)?;
            timeout(prompt_timeout, prompt)
                .await
                .map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
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

#[cfg(test)]
mod tests;
