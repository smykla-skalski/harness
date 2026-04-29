use std::future::pending;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use agent_client_protocol::schema::{
    CancelNotification, ContentBlock, NewSessionRequest, PromptRequest, SessionId, TextContent,
};
use agent_client_protocol::{Agent, ConnectionTo, Result as AcpResult};
use tokio::sync::mpsc as tokio_mpsc;
use tokio::time::timeout;

use super::session_guard::{RouteTarget, SessionRouteGuard};
use crate::daemon::agent_acp::prompt_gate::PromptLease;

pub(super) type ProtocolCommandResult<T> = Result<T, String>;

#[derive(Clone)]
pub(in crate::daemon::agent_acp) struct AcpProtocolHandle {
    cancel_tx: tokio_mpsc::UnboundedSender<()>,
    command_tx: tokio_mpsc::UnboundedSender<ProtocolCommand>,
}

pub(super) enum ProtocolCommand {
    AttachSession {
        acp_id: String,
        session_id: String,
        project_dir: PathBuf,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<SessionId>>,
    },
    PromptSession {
        acp_id: String,
        session_id: String,
        project_dir: PathBuf,
        prompt: String,
        prompt_lease: PromptLease,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<SessionId>>,
    },
    DetachTarget {
        target: RouteTarget,
        response_tx: mpsc::SyncSender<ProtocolCommandResult<()>>,
    },
}

impl AcpProtocolHandle {
    pub(super) fn new(
        cancel_tx: tokio_mpsc::UnboundedSender<()>,
        command_tx: tokio_mpsc::UnboundedSender<ProtocolCommand>,
    ) -> Self {
        Self {
            cancel_tx,
            command_tx,
        }
    }

    pub(in crate::daemon::agent_acp) fn cancel(&self) {
        let _ = self.cancel_tx.send(());
    }

    pub(in crate::daemon::agent_acp) fn attach_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
    ) -> ProtocolCommandResult<SessionId> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.command_tx
            .send(ProtocolCommand::AttachSession {
                acp_id: acp_id.to_string(),
                session_id: session_id.to_string(),
                project_dir,
                response_tx,
            })
            .map_err(|_| "ACP protocol command channel is closed".to_string())?;
        receive_response(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn prompt_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
        prompt: String,
        prompt_lease: PromptLease,
    ) -> ProtocolCommandResult<SessionId> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.command_tx
            .send(ProtocolCommand::PromptSession {
                acp_id: acp_id.to_string(),
                session_id: session_id.to_string(),
                project_dir,
                prompt,
                prompt_lease,
                response_tx,
            })
            .map_err(|_| "ACP protocol command channel is closed".to_string())?;
        receive_response(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn detach_session(
        &self,
        acp_id: &str,
        session_id: &str,
    ) -> ProtocolCommandResult<()> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.command_tx
            .send(ProtocolCommand::DetachTarget {
                target: RouteTarget {
                    acp_id: acp_id.to_string(),
                    session_id: session_id.to_string(),
                },
                response_tx,
            })
            .map_err(|_| "ACP protocol command channel is closed".to_string())?;
        receive_response(&response_rx)
    }
}

fn receive_response<T>(
    response_rx: &mpsc::Receiver<ProtocolCommandResult<T>>,
) -> ProtocolCommandResult<T> {
    response_rx
        .recv()
        .map_err(|_| "ACP protocol command response channel is closed".to_string())?
}

pub(super) async fn run_protocol_command_loop(
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
            response_tx,
        } => {
            let result =
                attach_protocol_session(connection, session_guard, acp_id, session_id, project_dir)
                    .await;
            let _ = response_tx.send(result);
        }
        ProtocolCommand::PromptSession {
            acp_id,
            session_id,
            project_dir,
            prompt,
            prompt_lease,
            response_tx,
        } => {
            let result = attach_prompt_session(
                connection,
                session_guard,
                prompt_timeout,
                AttachPromptInput {
                    acp_id,
                    session_id,
                    project_dir,
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
            let result = detach_protocol_session(connection, session_guard, &target);
            let _ = response_tx.send(result);
        }
    }
}

async fn attach_protocol_session(
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    acp_id: String,
    session_id: String,
    project_dir: PathBuf,
) -> ProtocolCommandResult<SessionId> {
    let response = connection
        .send_request(NewSessionRequest::new(project_dir))
        .block_task()
        .await
        .map_err(|error| error.to_string())?;
    let protocol_session_id = response.session_id;
    session_guard.start_session(&protocol_session_id, RouteTarget { acp_id, session_id });
    Ok(protocol_session_id)
}

async fn attach_prompt_session(
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    prompt_timeout: Duration,
    input: AttachPromptInput,
) -> ProtocolCommandResult<SessionId> {
    let AttachPromptInput {
        acp_id,
        session_id,
        project_dir,
        prompt,
        prompt_lease,
    } = input;
    let protocol_session_id =
        attach_protocol_session(connection, session_guard, acp_id, session_id, project_dir).await?;
    if let Err(error) = spawn_prompt_task(
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
    prompt: String,
    prompt_lease: PromptLease,
}

fn spawn_prompt_task(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    prompt: String,
    prompt_timeout: Duration,
    prompt_lease: PromptLease,
) -> AcpResult<()> {
    let prompt_connection = connection.clone();
    connection.spawn(async move {
        let result = send_prompt(&prompt_connection, session_id, prompt_timeout, prompt).await;
        drop(prompt_lease);
        result
    })
}

async fn send_prompt(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    prompt_timeout: Duration,
    prompt: String,
) -> AcpResult<()> {
    let request = PromptRequest::new(
        session_id,
        vec![ContentBlock::Text(TextContent::new(prompt))],
    );
    timeout(
        prompt_timeout,
        connection.send_request(request).block_task(),
    )
    .await
    .map_err(|_| super::deadline_error("session/prompt", prompt_timeout))??;
    Ok(())
}

fn detach_protocol_session(
    connection: &ConnectionTo<Agent>,
    session_guard: &SessionRouteGuard,
    target: &RouteTarget,
) -> ProtocolCommandResult<()> {
    let Some(protocol_session_id) = session_guard.stop_target(target) else {
        return Ok(());
    };
    match send_cancel_notification(connection, protocol_session_id.clone()) {
        Ok(()) => Ok(()),
        Err(error) => {
            session_guard.start_session(&protocol_session_id, target.clone());
            Err(error.to_string())
        }
    }
}

fn send_cancel_notification(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> AcpResult<()> {
    connection.send_notification(CancelNotification::new(session_id))
}
