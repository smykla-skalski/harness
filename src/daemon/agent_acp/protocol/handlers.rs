//! Client-request routing for the ACP connection.
//!
//! # Why some handlers spawn
//!
//! The SDK dispatch loop awaits an `on_receive_*` handler before it reads the
//! next message, so anything slow that runs inline stalls the whole
//! connection - including the `$/cancel_request` notification that would
//! release it. Handlers that can block on a human decision
//! (`session/request_permission`, and the write and terminal gates that go
//! through it) or on a child process (`terminal/wait_for_exit`) therefore run
//! on spawned tasks and answer from there. The remaining handlers are bounded
//! filesystem or bookkeeping calls and stay inline, which keeps their ordering
//! guarantees.
//!
//! Spawned handlers also observe cancellation: [`run_cancellable`] trips the
//! call's [`ClientCallCancel`] when the agent cancels the request, so the
//! waiting code unwinds and answers instead of holding a blocking thread.

use std::sync::Arc;

use agent_client_protocol::schema::v1::{
    CreateTerminalRequest, KillTerminalRequest, ReadTextFileRequest, ReleaseTerminalRequest,
    RequestPermissionRequest, SessionNotification, TerminalOutputRequest,
    WaitForTerminalExitRequest, WriteTextFileRequest,
};
use agent_client_protocol::{
    Agent, Client, ConnectTo, ConnectionTo, JsonRpcResponse, RequestCancellation, Responder,
    Result as AcpResult,
};
use tokio::sync::mpsc;

use crate::agents::acp::batcher::RoutedSessionNotification;
use crate::agents::acp::client::{ClientCallCancel, ClientResult};
use crate::agents::acp::supervision::AcpSessionSupervisor;

use super::AcpAgentManagerHandle;
use super::context::{ProtocolContext, respond_client_result};
use super::runtime_helpers::route_session_notification;
use super::session_guard::SessionRouteGuard;

pub(super) struct ClientHandlers {
    pub(super) context: ProtocolContext,
    pub(super) session_guard: Arc<SessionRouteGuard>,
    pub(super) supervisor: Arc<AcpSessionSupervisor>,
    pub(super) manager: AcpAgentManagerHandle,
    pub(super) notifications: mpsc::Sender<RoutedSessionNotification>,
}

/// Build the harness ACP client, register every handler, and run `main_fn`
/// against the connected agent.
#[expect(
    clippy::too_many_lines,
    reason = "ACP request routing is one registration table; splitting it would hide which handlers spawn"
)]
pub(super) async fn connect_with_client_handlers<R>(
    transport: impl ConnectTo<Client> + 'static,
    handlers: ClientHandlers,
    main_fn: impl AsyncFnOnce(ConnectionTo<Agent>) -> AcpResult<R>,
) -> AcpResult<R> {
    let ClientHandlers {
        context,
        session_guard,
        supervisor,
        manager,
        notifications,
    } = handlers;
    let read_context = context.clone();
    let write_context = context.clone();
    let create_terminal_context = context.clone();
    let terminal_output_context = context.clone();
    let release_terminal_context = context.clone();
    let wait_terminal_context = context.clone();
    let kill_terminal_context = context.clone();
    let permission_context = context;
    Client
        .builder()
        .name("harness")
        .on_receive_notification(
            async move |notification: SessionNotification, _connection| {
                route_session_notification(
                    &session_guard,
                    &supervisor,
                    &manager,
                    &notifications,
                    notification,
                )
                .await
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: ReadTextFileRequest, responder, _connection| {
                respond_client_result(
                    responder,
                    read_context.clone().read_text_file(request).await,
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WriteTextFileRequest, responder, connection| {
                let context = write_context.clone();
                spawn_cancellable(&connection, responder, move |cancel| {
                    context.write_text_file(request, cancel)
                })
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: CreateTerminalRequest, responder, connection| {
                let context = create_terminal_context.clone();
                spawn_cancellable(&connection, responder, move |cancel| {
                    context.create_terminal(request, cancel)
                })
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
                    release_terminal_context
                        .clone()
                        .release_terminal(request)
                        .await,
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: WaitForTerminalExitRequest, responder, connection| {
                let context = wait_terminal_context.clone();
                spawn_cancellable(&connection, responder, move |cancel| {
                    context.wait_for_terminal_exit(request, cancel)
                })
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: KillTerminalRequest, responder, _connection| {
                respond_client_result(
                    responder,
                    kill_terminal_context.clone().kill_terminal(request).await,
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, connection| {
                let context = permission_context.clone();
                spawn_cancellable(&connection, responder, move |cancel| {
                    context.request_permission(request, cancel)
                })
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(transport, main_fn)
        .await
}

/// Answer a client request from a spawned task so the dispatch loop stays free,
/// tripping the call's cancel token if the agent cancels the request.
fn spawn_cancellable<Response, Work, Fut>(
    connection: &ConnectionTo<Agent>,
    responder: Responder<Response>,
    work: Work,
) -> AcpResult<()>
where
    Response: JsonRpcResponse + Send + 'static,
    Work: FnOnce(ClientCallCancel) -> Fut + Send + 'static,
    Fut: Future<Output = ClientResult<Response>> + Send,
{
    connection.spawn(async move {
        let cancellation = responder.cancellation();
        let cancel = ClientCallCancel::default();
        let result = run_cancellable(work(cancel.clone()), &cancellation, &cancel).await;
        respond_client_result(responder, result)
    })
}

/// Run `work`, tripping `cancel` if the agent cancels the request.
///
/// The work is always awaited to completion: cancellation asks the waiting
/// code to unwind, and its answer (a cancelled outcome or an error) is what
/// the agent receives.
async fn run_cancellable<T>(
    work: impl Future<Output = ClientResult<T>>,
    cancellation: &RequestCancellation,
    cancel: &ClientCallCancel,
) -> ClientResult<T> {
    let mut work = std::pin::pin!(work);
    tokio::select! {
        biased;
        result = &mut work => result,
        () = cancellation.cancelled() => {
            cancel.cancel();
            work.await
        }
    }
}
