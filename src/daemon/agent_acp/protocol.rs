use std::future::pending;
use std::io;
use std::path::PathBuf;
use std::process::Child;
use std::sync::Arc;
use std::time::Duration;

use agent_client_protocol::schema::{
    ContentBlock, CreateTerminalRequest, InitializeRequest, KillTerminalRequest, NewSessionRequest,
    PromptRequest, ProtocolVersion, ReadTextFileRequest, ReleaseTerminalRequest,
    RequestPermissionRequest, SessionNotification, TerminalOutputRequest, TextContent,
    WaitForTerminalExitRequest, WriteTextFileRequest,
};
use agent_client_protocol::{
    Agent, ByteStreams, Client, ConnectionTo, Error as AcpError, Responder,
};
use tokio::process::{ChildStdin, ChildStdout};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::task::spawn_blocking;
use tokio::time::timeout;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

use crate::agents::acp::batcher::spawn_notification_batcher;
use crate::agents::acp::client::{ClientError, ClientResult, HarnessAcpClient};
use crate::agents::acp::connection::{ConnectionConfig, EventBatch};
use crate::agents::acp::permission::PermissionMode;
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::hooks::runner_policy::managed_cluster_binaries;

use super::manager::AcpAgentStartRequest;

const ACP_DEADLINE_EXCEEDED: i32 = -32090;

pub(super) fn spawn_protocol_task(
    child: &mut Child,
    request: &AcpAgentStartRequest,
    session_id: String,
    agent_name: String,
    project_dir: PathBuf,
    supervisor: &Arc<AcpSessionSupervisor>,
    permission_mode: PermissionMode,
) -> io::Result<(mpsc::Receiver<EventBatch>, JoinHandle<()>, JoinHandle<()>)> {
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
        session_id,
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
    let protocol_task = tokio::spawn(run_protocol(
        stdin,
        stdout,
        project_dir,
        request.prompt.clone(),
        batcher.notifications,
        client,
        Arc::clone(supervisor),
    ));
    Ok((batcher.events, protocol_task, batcher.task))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "ACP SDK requires one typed callback registration per request type"
)]
async fn run_protocol(
    stdin: ChildStdin,
    stdout: ChildStdout,
    project_dir: PathBuf,
    prompt: Option<String>,
    notifications: mpsc::Sender<SessionNotification>,
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
) {
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let context = ProtocolContext {
        client,
        supervisor: Arc::clone(&supervisor),
    };
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
            run_connection(connection, project_dir, prompt, supervisor).await
        })
        .await;
    if let Err(error) = result {
        tracing::warn!(%error, "ACP protocol task stopped");
    }
}

async fn run_connection(
    connection: ConnectionTo<Agent>,
    project_dir: PathBuf,
    prompt: Option<String>,
    supervisor: Arc<AcpSessionSupervisor>,
) -> agent_client_protocol::Result<()> {
    let initialize_timeout = supervisor.config().initialize_timeout;
    let prompt_timeout = supervisor.config().prompt_timeout;

    timeout(
        initialize_timeout,
        connection
            .send_request(InitializeRequest::new(ProtocolVersion::V1))
            .block_task(),
    )
    .await
    .map_err(|_| deadline_error("session/initialize", initialize_timeout))??;

    let response = connection
        .send_request(NewSessionRequest::new(project_dir))
        .block_task()
        .await?;

    if let Some(prompt) = prompt.filter(|value| !value.trim().is_empty()) {
        let request = PromptRequest::new(
            response.session_id,
            vec![ContentBlock::Text(TextContent::new(prompt))],
        );
        timeout(
            prompt_timeout,
            connection.send_request(request).block_task(),
        )
        .await
        .map_err(|_| deadline_error("session/prompt", prompt_timeout))??;
    }
    pending::<agent_client_protocol::Result<()>>().await
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

#[derive(Clone)]
struct ProtocolContext {
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
}

impl ProtocolContext {
    fn read_text_file(
        &self,
        request: &ReadTextFileRequest,
    ) -> ClientResult<<ReadTextFileRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_read_text_file(request)
        })
    }

    fn write_text_file(
        &self,
        request: &WriteTextFileRequest,
    ) -> ClientResult<<WriteTextFileRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_write_text_file(request)
        })
    }

    fn create_terminal(
        &self,
        request: &CreateTerminalRequest,
    ) -> ClientResult<<CreateTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_create_terminal(request)
        })
    }

    fn terminal_output(
        &self,
        request: &TerminalOutputRequest,
    ) -> ClientResult<<TerminalOutputRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_terminal_output(request)
        })
    }

    fn release_terminal(
        &self,
        request: &ReleaseTerminalRequest,
    ) -> ClientResult<<ReleaseTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_release_terminal(request)
        })
    }

    fn wait_for_terminal_exit(
        &self,
        request: &WaitForTerminalExitRequest,
    ) -> ClientResult<<WaitForTerminalExitRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_wait_for_terminal_exit(request)
        })
    }

    fn kill_terminal(
        &self,
        request: &KillTerminalRequest,
    ) -> ClientResult<<KillTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        with_client_call(&self.supervisor, || {
            self.client.handle_kill_terminal(request)
        })
    }

    async fn request_permission(
        self,
        request: RequestPermissionRequest,
    ) -> ClientResult<<RequestPermissionRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        spawn_blocking(move || {
            with_client_call(&self.supervisor, || {
                self.client.handle_request_permission(&request)
            })
        })
        .await
        .map_err(|error| ClientError::new(-32603, format!("join permission bridge: {error}")))?
    }
}

async fn handle_permission_request(
    request: RequestPermissionRequest,
    responder: Responder<
        <RequestPermissionRequest as agent_client_protocol::JsonRpcRequest>::Response,
    >,
    context: ProtocolContext,
) -> agent_client_protocol::Result<()> {
    let result = context.request_permission(request).await;
    respond_client_result(responder, result)
}

fn with_client_call<T>(
    supervisor: &AcpSessionSupervisor,
    work: impl FnOnce() -> ClientResult<T>,
) -> ClientResult<T> {
    let _guard = supervisor.enter_client_call();
    work()
}

fn respond_client_result<T>(
    responder: Responder<T>,
    result: ClientResult<T>,
) -> agent_client_protocol::Result<()>
where
    T: agent_client_protocol::JsonRpcResponse,
{
    match result {
        Ok(response) => responder.respond(response),
        Err(error) => responder.respond_with_error(client_error_to_acp(error)),
    }
}

fn client_error_to_acp(error: ClientError) -> AcpError {
    AcpError::new(error.code, error.message)
}
