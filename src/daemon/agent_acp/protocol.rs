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
use tokio::sync::mpsc;
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
use crate::hooks::runner_policy::managed_cluster_binaries;

use super::manager::AcpAgentStartRequest;
mod commands;
mod context;
mod session_guard;
pub(super) use commands::AcpProtocolHandle;
use commands::{ProtocolCommand, run_protocol_command_loop};
use context::{
    ProtocolContext, client_error_to_acp, handle_permission_request, respond_client_result,
};
use session_guard::{RouteTarget, SessionRouteGuard};
const ACP_DEADLINE_EXCEEDED: i32 = -32090;
const SESSION_ROUTE_DRAIN_GRACE: Duration = Duration::from_millis(75);
pub(super) struct SpawnedAcpProtocol {
    pub(super) events: mpsc::Receiver<EventBatch>,
    pub(super) disconnects: mpsc::Receiver<DisconnectReason>,
    pub(super) protocol: JoinHandle<()>,
    pub(super) batcher: JoinHandle<()>,
    pub(super) handle: AcpProtocolHandle,
}

pub(super) struct SpawnProtocolInput<'a> {
    pub request: &'a AcpAgentStartRequest,
    pub acp_id: &'a str,
    pub session_id: &'a str,
    pub agent_name: String,
    pub project_dir: PathBuf,
    pub supervisor: &'a Arc<AcpSessionSupervisor>,
    pub permission_mode: PermissionMode,
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
        project_dir,
        supervisor,
        permission_mode,
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
    let protocol_task = tokio::spawn(run_protocol(RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt: request.prompt.clone(),
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        notifications: batcher.notifications,
        client,
        supervisor: Arc::clone(supervisor),
        cancel_rx,
        command_rx,
        disconnect_tx,
    }));
    Ok(SpawnedAcpProtocol {
        events: batcher.events,
        disconnects,
        protocol: protocol_task,
        batcher: batcher.task,
        handle: AcpProtocolHandle::new(cancel_tx, command_tx),
    })
}

struct RunProtocolArgs {
    stdin: ChildStdin,
    stdout: ChildStdout,
    project_dir: PathBuf,
    prompt: Option<String>,
    acp_id: String,
    session_id: String,
    notifications: mpsc::Sender<RoutedSessionNotification>,
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    command_rx: mpsc::UnboundedReceiver<ProtocolCommand>,
    disconnect_tx: mpsc::Sender<DisconnectReason>,
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
        notifications,
        client,
        supervisor,
        cancel_rx,
        command_rx,
        disconnect_tx,
    } = args;
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
                let target = match notification_guard.ensure_known(&notification.session_id) {
                    Ok(target) => target,
                    Err(error) => {
                        if error.message.contains("already ended") {
                            tracing::debug!(
                                session_id = %notification.session_id,
                                "dropping late ACP notification after session shutdown"
                            );
                            return Ok(());
                        }
                        return Err(client_error_to_acp(error));
                    }
                };
                let routed = RoutedSessionNotification {
                    acp_id: target.acp_id,
                    session_id: target.session_id,
                    notification,
                };
                notifications
                    .send(routed)
                    .await
                    .map_err(|error| AcpError::new(-32603, format!("queue ACP event: {error}")))?;
                Ok(())
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
                supervisor,
                cancel_rx,
                command_rx,
                session_guard,
            })
            .await
        })
        .await;
    report_protocol_result(result, disconnect_tx).await;
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
        supervisor,
        mut cancel_rx,
        mut command_rx,
        session_guard,
    } = args;
    let initialize_timeout = supervisor.config().initialize_timeout;
    let prompt_timeout = supervisor.config().prompt_timeout;

    send_initialize(&connection, initialize_timeout).await?;
    let acp_session_id = send_new_session(&connection, project_dir).await?;
    session_guard.start_session(&acp_session_id, RouteTarget { acp_id, session_id });
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
        )
        .await
    }
    .await;
    // Keep route validation active for a short grace window after we have
    // requested cancel so in-flight notifications are not immediately marked
    // stale while transport shutdown is still propagating.
    sleep(SESSION_ROUTE_DRAIN_GRACE).await;
    session_guard.stop_session(&acp_session_id);
    run_result
}

struct RunConnectionArgs {
    connection: ConnectionTo<Agent>,
    project_dir: PathBuf,
    prompt: Option<String>,
    acp_id: String,
    session_id: String,
    supervisor: Arc<AcpSessionSupervisor>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    command_rx: mpsc::UnboundedReceiver<ProtocolCommand>,
    session_guard: Arc<SessionRouteGuard>,
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
    tokio::select! {
        result = timeout(prompt_timeout, connection.send_request(request).block_task()) => {
            result.map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
            Ok(false)
        }
        Some(()) = cancel_rx.recv() => {
            send_cancel_notification(connection, session_id)?;
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
