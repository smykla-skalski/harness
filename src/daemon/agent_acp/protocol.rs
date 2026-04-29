use std::future::pending;
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
    Agent, ByteStreams, Client, ConnectionTo, Error as AcpError, ErrorCode,
};
use tokio::process::{ChildStdin, ChildStdout};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

use crate::agents::acp::batcher::spawn_notification_batcher;
use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::connection::{ConnectionConfig, EventBatch};
use crate::agents::acp::permission::PermissionMode;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::agents::kind::DisconnectReason;
use crate::hooks::runner_policy::managed_cluster_binaries;

use super::manager::AcpAgentStartRequest;
mod context;
mod session_guard;
use context::{
    ProtocolContext, client_error_to_acp, handle_permission_request, respond_client_result,
};
use session_guard::SessionRouteGuard;
const ACP_DEADLINE_EXCEEDED: i32 = -32090;

#[derive(Clone)]
pub(super) struct AcpCancelHandle {
    tx: mpsc::UnboundedSender<()>,
}

impl AcpCancelHandle {
    pub(super) fn cancel(&self) {
        let _ = self.tx.send(());
    }
}
pub(super) struct SpawnedAcpProtocol {
    pub(super) events: mpsc::Receiver<EventBatch>,
    pub(super) disconnects: mpsc::Receiver<DisconnectReason>,
    pub(super) protocol: JoinHandle<()>,
    pub(super) batcher: JoinHandle<()>,
    pub(super) cancel: AcpCancelHandle,
}
pub(super) fn spawn_protocol_task(
    child: &mut Child,
    request: &AcpAgentStartRequest,
    session_id: &str,
    agent_name: String,
    project_dir: PathBuf,
    supervisor: &Arc<AcpSessionSupervisor>,
    permission_mode: PermissionMode,
) -> io::Result<SpawnedAcpProtocol> {
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
        session_id.to_string(),
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
    let (disconnect_tx, disconnects) = mpsc::channel(1);
    let protocol_task = tokio::spawn(run_protocol(RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt: request.prompt.clone(),
        notifications: batcher.notifications,
        client,
        supervisor: Arc::clone(supervisor),
        cancel_rx,
        disconnect_tx,
    }));
    Ok(SpawnedAcpProtocol {
        events: batcher.events,
        disconnects,
        protocol: protocol_task,
        batcher: batcher.task,
        cancel: AcpCancelHandle { tx: cancel_tx },
    })
}

struct RunProtocolArgs {
    stdin: ChildStdin,
    stdout: ChildStdout,
    project_dir: PathBuf,
    prompt: Option<String>,
    notifications: mpsc::Sender<SessionNotification>,
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
    cancel_rx: mpsc::UnboundedReceiver<()>,
    disconnect_tx: mpsc::Sender<DisconnectReason>,
}

async fn run_protocol(args: RunProtocolArgs) {
    let RunProtocolArgs {
        stdin,
        stdout,
        project_dir,
        prompt,
        notifications,
        client,
        supervisor,
        cancel_rx,
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
                if let Err(error) = notification_guard.ensure_known(&notification.session_id) {
                    return Err(client_error_to_acp(error));
                }
                notifications
                    .send(notification)
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
            run_connection(
                connection,
                project_dir,
                prompt,
                supervisor,
                cancel_rx,
                session_guard,
            )
            .await
        })
        .await;
    report_protocol_result(result, disconnect_tx).await;
}

async fn report_protocol_result(
    result: agent_client_protocol::Result<()>,
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

async fn run_connection(
    connection: ConnectionTo<Agent>,
    project_dir: PathBuf,
    prompt: Option<String>,
    supervisor: Arc<AcpSessionSupervisor>,
    mut cancel_rx: mpsc::UnboundedReceiver<()>,
    session_guard: Arc<SessionRouteGuard>,
) -> agent_client_protocol::Result<()> {
    let initialize_timeout = supervisor.config().initialize_timeout;
    let prompt_timeout = supervisor.config().prompt_timeout;

    send_initialize(&connection, initialize_timeout).await?;
    let session_id = send_new_session(&connection, project_dir).await?;
    session_guard.start_session(session_id.clone());
    let run_result = async {
        if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
            let cancelled = send_prompt_or_cancel(
                &connection,
                &mut cancel_rx,
                session_id.clone(),
                prompt_timeout,
                prompt,
            )
            .await?;
            if cancelled {
                return Ok(());
            }
        }
        wait_for_cancel(&connection, &mut cancel_rx, session_id.clone()).await
    }
    .await;
    session_guard.stop_session(&session_id);
    run_result
}

async fn send_initialize(
    connection: &ConnectionTo<Agent>,
    initialize_timeout: Duration,
) -> agent_client_protocol::Result<()> {
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
) -> agent_client_protocol::Result<SessionId> {
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
) -> agent_client_protocol::Result<bool> {
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

async fn wait_for_cancel(
    connection: &ConnectionTo<Agent>,
    cancel_rx: &mut mpsc::UnboundedReceiver<()>,
    session_id: SessionId,
) -> agent_client_protocol::Result<()> {
    if cancel_rx.recv().await.is_some() {
        send_cancel_notification(connection, session_id)?;
        Ok(())
    } else {
        pending::<agent_client_protocol::Result<()>>().await
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
) -> agent_client_protocol::Result<()> {
    connection.send_notification(CancelNotification::new(session_id))
}

#[cfg(test)]
mod tests;
