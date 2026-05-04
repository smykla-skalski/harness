use std::sync::Arc;

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReadTextFileRequest, ReleaseTerminalRequest,
    RequestPermissionRequest, TerminalOutputRequest, WaitForTerminalExitRequest,
    WriteTextFileRequest,
};
use agent_client_protocol::{Error as AcpError, Responder};
use tokio::task::spawn_blocking;

use crate::agents::acp::client::{ClientError, ClientResult, HarnessAcpClient};
use crate::agents::acp::supervision::AcpSessionSupervisor;

use super::session_guard::SessionRouteGuard;

#[derive(Clone)]
pub(super) struct ProtocolContext {
    client: Arc<HarnessAcpClient>,
    supervisor: Arc<AcpSessionSupervisor>,
    session_guard: Arc<SessionRouteGuard>,
}

impl ProtocolContext {
    pub(super) fn new(
        client: Arc<HarnessAcpClient>,
        supervisor: Arc<AcpSessionSupervisor>,
        session_guard: Arc<SessionRouteGuard>,
    ) -> Self {
        Self {
            client,
            supervisor,
            session_guard,
        }
    }

    pub(super) fn read_text_file(
        &self,
        request: &ReadTextFileRequest,
    ) -> ClientResult<<ReadTextFileRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        with_client_call(&self.supervisor, || {
            self.client.handle_read_text_file(request)
        })
    }

    pub(super) async fn write_text_file(
        self,
        request: WriteTextFileRequest,
    ) -> ClientResult<<WriteTextFileRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        spawn_blocking_client_call(
            self.supervisor,
            self.client,
            "join write_text_file",
            move |client| client.handle_write_text_file(&request),
        )
        .await
    }

    pub(super) async fn create_terminal(
        self,
        request: CreateTerminalRequest,
    ) -> ClientResult<<CreateTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        spawn_blocking_client_call(
            self.supervisor,
            self.client,
            "join create_terminal",
            move |client| client.handle_create_terminal(&request),
        )
        .await
    }

    pub(super) fn terminal_output(
        &self,
        request: &TerminalOutputRequest,
    ) -> ClientResult<<TerminalOutputRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        with_client_call(&self.supervisor, || {
            self.client.handle_terminal_output(request)
        })
    }

    pub(super) fn release_terminal(
        &self,
        request: &ReleaseTerminalRequest,
    ) -> ClientResult<<ReleaseTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        with_client_call(&self.supervisor, || {
            self.client.handle_release_terminal(request)
        })
    }

    pub(super) fn wait_for_terminal_exit(
        &self,
        request: &WaitForTerminalExitRequest,
    ) -> ClientResult<<WaitForTerminalExitRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        with_client_call(&self.supervisor, || {
            self.client.handle_wait_for_terminal_exit(request)
        })
    }

    pub(super) fn kill_terminal(
        &self,
        request: &KillTerminalRequest,
    ) -> ClientResult<<KillTerminalRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        with_client_call(&self.supervisor, || {
            self.client.handle_kill_terminal(request)
        })
    }

    pub(super) async fn request_permission(
        self,
        request: RequestPermissionRequest,
    ) -> ClientResult<<RequestPermissionRequest as agent_client_protocol::JsonRpcRequest>::Response>
    {
        let _target = self.session_guard.ensure_known(&request.session_id)?;
        spawn_blocking_client_call(
            self.supervisor,
            self.client,
            "join permission bridge",
            move |client| client.handle_request_permission(&request),
        )
        .await
    }
}

pub(super) async fn handle_permission_request(
    request: RequestPermissionRequest,
    responder: Responder<
        <RequestPermissionRequest as agent_client_protocol::JsonRpcRequest>::Response,
    >,
    context: ProtocolContext,
) -> agent_client_protocol::Result<()> {
    let result = context.request_permission(request).await;
    respond_client_result(responder, result)
}

pub(super) fn respond_client_result<T>(
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

pub(super) fn client_error_to_acp(error: ClientError) -> AcpError {
    AcpError::new(error.code, error.message)
}

fn with_client_call<T>(
    supervisor: &AcpSessionSupervisor,
    work: impl FnOnce() -> ClientResult<T>,
) -> ClientResult<T> {
    let _guard = supervisor.enter_client_call();
    work()
}

async fn spawn_blocking_client_call<T>(
    supervisor: Arc<AcpSessionSupervisor>,
    client: Arc<HarnessAcpClient>,
    join_label: &'static str,
    work: impl FnOnce(&HarnessAcpClient) -> ClientResult<T> + Send + 'static,
) -> ClientResult<T>
where
    T: Send + 'static,
{
    spawn_blocking(move || with_client_call(&supervisor, || work(client.as_ref())))
        .await
        .map_err(|error| ClientError::new(-32603, format!("{join_label}: {error}")))?
}
