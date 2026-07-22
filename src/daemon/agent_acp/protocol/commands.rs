use std::future::pending;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

use tokio::time::Instant;

use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, ListSessionsRequest, LogoutRequest, PromptRequest, SessionId,
    TextContent,
};
use agent_client_protocol::{Agent, ConnectionTo, Result as AcpResult};
use tokio::sync::mpsc as tokio_mpsc;
use tokio::time::timeout;

use super::lifecycle;
use crate::daemon::agent_acp::AcpSessionListPage;

use super::session_config::{
    AcpSessionRequestConfig, advertised_session_configuration,
    apply_requested_session_configuration,
};
use super::session_guard::{RouteTarget, SessionRouteGuard};
use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::agent_acp::prompt_gate::PromptLease;

pub(super) type ProtocolCommandResult<T> = Result<T, String>;

/// How long a detach waits for the agent to confirm the session is closed.
///
/// Short because someone is stopping one agent and waiting on the reply, and
/// the process-lifecycle lock is held for the whole call. The lifecycle budget
/// would bound it too, but at a latency nobody wants on an interactive stop.
const DETACH_CLOSE_BUDGET: Duration = Duration::from_secs(2);

mod handle;

pub(in crate::daemon::agent_acp) use handle::AcpProtocolHandle;
pub(super) use handle::response_timeout_for;

pub(super) enum ProtocolCommand {
    AttachSession {
        acp_id: String,
        session_id: String,
        project_dir: PathBuf,
        session_config: AcpSessionRequestConfig,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<SessionId>>,
    },
    PromptSession {
        acp_id: String,
        session_id: String,
        project_dir: PathBuf,
        session_config: AcpSessionRequestConfig,
        prompt: String,
        prompt_lease: PromptLease,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<SessionId>>,
    },
    DetachTarget {
        target: RouteTarget,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<()>>,
    },
    Logout {
        response_tx: mpsc::SyncSender<ProtocolCommandResult<()>>,
    },
    ListSessions {
        request: ListSessionsRequest,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<AcpSessionListPage>>,
    },
    CloseSession {
        session_id: SessionId,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<()>>,
    },
    DeleteSession {
        session_id: SessionId,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<()>>,
    },
    CloseRoutedSessions {
        budget: Duration,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<usize>>,
    },
}

pub(super) async fn run_protocol_command_loop(
    supervisor: Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    cancel_rx: &mut tokio_mpsc::UnboundedReceiver<()>,
    command_rx: &mut tokio_mpsc::UnboundedReceiver<ProtocolCommand>,
    session_guard: &SessionRouteGuard,
    primary_session_id: SessionId,
    prompt_timeout: Duration,
) -> AcpResult<()> {
    loop {
        tokio::select! {
            Some(()) = cancel_rx.recv() => {
                send_cancel_notification(connection, primary_session_id)?;
                return Ok(());
            }
            Some(command) = command_rx.recv() => {
                handle_protocol_command(
                    Arc::clone(&supervisor),
                    connection,
                    session_guard,
                    command,
                    prompt_timeout,
                ).await;
            }
            else => return pending::<AcpResult<()>>().await,
        }
    }
}

async fn handle_protocol_command(
    supervisor: Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    command: ProtocolCommand,
    prompt_timeout: Duration,
) {
    match command {
        ProtocolCommand::AttachSession {
            acp_id,
            session_id,
            project_dir,
            session_config,
            response_tx,
        } => {
            let result = attach_protocol_session(
                &supervisor,
                connection,
                session_guard,
                acp_id,
                session_id,
                project_dir,
                &session_config,
            )
            .await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::PromptSession {
            acp_id,
            session_id,
            project_dir,
            session_config,
            prompt,
            prompt_lease,
            response_tx,
        } => {
            let result = attach_prompt_session(
                Arc::clone(&supervisor),
                connection,
                session_guard,
                prompt_timeout,
                AttachPromptInput {
                    acp_id,
                    session_id,
                    project_dir,
                    session_config,
                    prompt,
                    prompt_lease,
                },
            )
            .await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::DetachTarget {
            target,
            response_tx,
        } => {
            let result =
                detach_protocol_session(&supervisor, connection, session_guard, &target).await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::CloseRoutedSessions {
            budget,
            response_tx,
        } => {
            let result =
                close_routed_sessions(&supervisor, connection, session_guard, budget).await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::Logout { response_tx } => {
            let result = send_logout(&supervisor, connection).await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::ListSessions {
            request,
            response_tx,
        } => {
            let result = lifecycle::list_sessions(&supervisor, connection, request).await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::CloseSession {
            session_id,
            response_tx,
        } => {
            let result = lifecycle::close_session(&supervisor, connection, session_id).await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::DeleteSession {
            session_id,
            response_tx,
        } => {
            let result = lifecycle::delete_session(&supervisor, connection, session_id).await;
            let _ = response_tx.send(result);
        }
    }
}

async fn send_logout(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
) -> ProtocolCommandResult<()> {
    let supported = supervisor
        .handshake()
        .is_some_and(|handshake| handshake.supports_logout);
    if !supported {
        return Err("agent does not advertise the auth.logout capability".to_string());
    }
    let _guard = supervisor.enter_pending_request_with_reason(Some("logout"));
    lifecycle::with_deadline(
        supervisor,
        "logout",
        connection.send_request(LogoutRequest::new()).block_task(),
    )
    .await?;
    Ok(())
}

async fn attach_protocol_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    acp_id: String,
    session_id: String,
    project_dir: PathBuf,
    session_config: &AcpSessionRequestConfig,
) -> ProtocolCommandResult<SessionId> {
    let request = super::session_inputs::new_session_request(
        project_dir,
        session_config,
        supervisor.handshake(),
    );
    let response = {
        let _guard = supervisor.enter_pending_request_with_reason(Some("session/new"));
        lifecycle::with_deadline(
            supervisor,
            "session/new",
            connection.send_request(request).block_task(),
        )
        .await?
    };
    let protocol_session_id = response.session_id.clone();
    session_guard.start_session(&protocol_session_id, RouteTarget { acp_id, session_id });
    if let Err(error) = apply_requested_session_configuration(
        supervisor,
        connection,
        &protocol_session_id,
        session_config,
        advertised_session_configuration(response.config_options.as_deref()),
    )
    .await
    {
        session_guard.stop_session(&protocol_session_id);
        let _ = send_cancel_notification(connection, protocol_session_id.clone());
        return Err(error.to_string());
    }
    Ok(protocol_session_id)
}

async fn attach_prompt_session(
    supervisor: Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    prompt_timeout: Duration,
    input: AttachPromptInput,
) -> ProtocolCommandResult<SessionId> {
    let AttachPromptInput {
        acp_id,
        session_id,
        project_dir,
        session_config,
        prompt,
        prompt_lease,
    } = input;
    let protocol_session_id = attach_protocol_session(
        &supervisor,
        connection,
        session_guard,
        acp_id,
        session_id,
        project_dir,
        &session_config,
    )
    .await?;
    if let Err(error) = spawn_prompt_task(
        Arc::clone(&supervisor),
        connection,
        protocol_session_id.clone(),
        prompt,
        prompt_timeout,
        prompt_lease,
    ) {
        session_guard.stop_session(&protocol_session_id);
        let _ = send_cancel_notification(connection, protocol_session_id);
        return Err(error.to_string());
    }
    Ok(protocol_session_id)
}

struct AttachPromptInput {
    acp_id: String,
    session_id: String,
    project_dir: PathBuf,
    session_config: AcpSessionRequestConfig,
    prompt: String,
    prompt_lease: PromptLease,
}

fn spawn_prompt_task(
    supervisor: Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    prompt: String,
    prompt_timeout: Duration,
    prompt_lease: PromptLease,
) -> AcpResult<()> {
    let prompt_connection = connection.clone();
    connection.spawn(async move {
        let result = send_prompt(
            &supervisor,
            &prompt_connection,
            session_id,
            prompt_timeout,
            prompt,
        )
        .await;
        drop(prompt_lease);
        result
    })
}

async fn send_prompt(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    prompt_timeout: Duration,
    prompt: String,
) -> AcpResult<()> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/prompt"));
    let request = PromptRequest::new(
        session_id,
        vec![ContentBlock::Text(TextContent::new(prompt))],
    );
    let response = timeout(
        prompt_timeout,
        connection.send_request(request).block_task(),
    )
    .await
    .map_err(|_| super::deadline_error("session/prompt", prompt_timeout))??;
    super::session_state::record_stop_reason(supervisor, &response);
    Ok(())
}

async fn detach_protocol_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    target: &RouteTarget,
) -> ProtocolCommandResult<()> {
    let Some(protocol_session_id) = session_guard.stop_target(target) else {
        return Ok(());
    };
    if let Err(error) = send_cancel_notification(connection, protocol_session_id.clone()) {
        session_guard.start_session(&protocol_session_id, target.clone());
        return Err(error.to_string());
    }
    close_detached_session(supervisor, connection, protocol_session_id).await;
    Ok(())
}

/// Tell the agent the session is finished once the route is gone.
///
/// Best effort on purpose: the route is already detached and the caller has
/// moved on, so a refusing or unreachable agent must not fail the detach. It
/// matters because a closed session is one the agent may persist and hand back
/// later, while a killed one is not.
///
/// Bounded well under the lifecycle budget because a detach comes from someone
/// stopping one agent and waiting on the answer, with the process-lifecycle
/// lock held for the whole call.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn close_detached_session(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    protocol_session_id: SessionId,
) {
    if !close_supported(supervisor) {
        return;
    }
    if !close_session_within(
        supervisor,
        connection,
        protocol_session_id.clone(),
        DETACH_CLOSE_BUDGET,
    )
    .await
    {
        tracing::warn!(session = %protocol_session_id, "could not close detached ACP session");
    }
}

fn close_supported(supervisor: &AcpSessionSupervisor) -> bool {
    supervisor
        .handshake()
        .is_some_and(|handshake| handshake.supports_session_close)
}

/// Close one session within `budget`, reporting whether the agent confirmed it.
async fn close_session_within(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    budget: Duration,
) -> bool {
    let close = lifecycle::close_session(supervisor, connection, session_id);
    matches!(timeout(budget, close).await, Ok(Ok(())))
}

/// Close every session this connection still routes, within one shared budget.
///
/// Teardown calls this before the tasks are aborted, because the command loop
/// that carries these requests dies with them. The budget covers the whole
/// sweep rather than each session, so one wedged agent cannot stretch shutdown
/// by the number of sessions it happens to hold.
async fn close_routed_sessions(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    budget: Duration,
) -> ProtocolCommandResult<usize> {
    if !close_supported(supervisor) {
        return Ok(0);
    }
    let deadline = Instant::now() + budget;
    let mut closed = 0;
    for session_id in session_guard.active_sessions() {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        if close_session_within(supervisor, connection, session_id, remaining).await {
            closed += 1;
        }
    }
    Ok(closed)
}

fn send_cancel_notification(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> AcpResult<()> {
    connection.send_notification(CancelNotification::new(session_id))
}

#[cfg(test)]
mod tests;
