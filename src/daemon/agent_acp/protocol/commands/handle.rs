//! The caller side of the protocol command channel.
//!
//! Every method here blocks a thread until the command loop answers, so each
//! one is bounded. The loop already bounds its own wire calls; this bound
//! covers the case where the loop itself stopped running.

use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use agent_client_protocol::schema::v1::{ListSessionsRequest, SessionId};
use tokio::sync::mpsc as tokio_mpsc;

use super::{ProtocolCommand, ProtocolCommandResult};
use crate::daemon::agent_acp::AcpSessionListPage;
use crate::daemon::agent_acp::prompt_gate::PromptLease;
use crate::daemon::agent_acp::protocol::session_config::AcpSessionRequestConfig;
use crate::daemon::agent_acp::protocol::session_guard::RouteTarget;

/// Extra time a reply may take beyond the command's own wire deadline.
const RESPONSE_GRACE: Duration = Duration::from_secs(5);

/// Scheduling slack on top of a sweep's own budget.
///
/// A sweep already bounds itself by the budget its caller chose, so the reply
/// only has to travel back over the channel. Far smaller than
/// [`RESPONSE_GRACE`] because daemon shutdown waits on this, and the budget is
/// meant to be the bound the caller actually gets.
const SWEEP_RESPONSE_GRACE: Duration = Duration::from_millis(500);

/// How long a caller waits for a reply, given the loop's per-request budget.
///
/// A reply that misses this is a loop that stopped running rather than a slow
/// agent, because the loop times out every request it makes.
#[must_use]
pub(in crate::daemon::agent_acp::protocol) fn response_timeout_for(
    lifecycle_timeout: Duration,
) -> Duration {
    lifecycle_timeout.saturating_add(RESPONSE_GRACE)
}

#[derive(Clone)]
pub(in crate::daemon::agent_acp) struct AcpProtocolHandle {
    cancel_tx: tokio_mpsc::UnboundedSender<()>,
    command_tx: tokio_mpsc::UnboundedSender<ProtocolCommand>,
    response_timeout: Duration,
}

impl AcpProtocolHandle {
    pub(in crate::daemon::agent_acp::protocol) fn new(
        cancel_tx: tokio_mpsc::UnboundedSender<()>,
        command_tx: tokio_mpsc::UnboundedSender<ProtocolCommand>,
        response_timeout: Duration,
    ) -> Self {
        Self {
            cancel_tx,
            command_tx,
            response_timeout,
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
        session_config: AcpSessionRequestConfig,
    ) -> ProtocolCommandResult<SessionId> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::AttachSession {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
            project_dir,
            session_config,
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn prompt_session(
        &self,
        acp_id: &str,
        session_id: &str,
        project_dir: PathBuf,
        session_config: AcpSessionRequestConfig,
        prompt: String,
        prompt_lease: PromptLease,
    ) -> ProtocolCommandResult<SessionId> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::PromptSession {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
            project_dir,
            session_config,
            prompt,
            prompt_lease,
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn detach_session(
        &self,
        acp_id: &str,
        session_id: &str,
    ) -> ProtocolCommandResult<()> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::DetachTarget {
            target: RouteTarget {
                acp_id: acp_id.to_string(),
                session_id: session_id.to_string(),
            },
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn logout(&self) -> ProtocolCommandResult<()> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::Logout { response_tx })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn list_sessions(
        &self,
        cwd: Option<PathBuf>,
        cursor: Option<String>,
    ) -> ProtocolCommandResult<AcpSessionListPage> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        let request = ListSessionsRequest::new().cwd(cwd).cursor(cursor);
        self.dispatch(ProtocolCommand::ListSessions {
            request,
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn close_session(
        &self,
        session_id: &str,
    ) -> ProtocolCommandResult<()> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::CloseSession {
            session_id: SessionId::new(session_id.to_string()),
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    pub(in crate::daemon::agent_acp) fn delete_session(
        &self,
        session_id: &str,
    ) -> ProtocolCommandResult<()> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::DeleteSession {
            session_id: SessionId::new(session_id.to_string()),
            response_tx,
        })?;
        self.receive(&response_rx)
    }

    /// Close every protocol session this connection still routes.
    ///
    /// Teardown issues this while the command loop is still alive, because the
    /// loop owns the route table and dies with the task that would carry the
    /// requests.
    pub(in crate::daemon::agent_acp) fn close_routed_sessions(
        &self,
        budget: Duration,
    ) -> ProtocolCommandResult<usize> {
        let (response_tx, response_rx) = mpsc::sync_channel(1);
        self.dispatch(ProtocolCommand::CloseRoutedSessions {
            budget,
            response_tx,
        })?;
        receive_response(&response_rx, budget.saturating_add(SWEEP_RESPONSE_GRACE))
    }

    fn dispatch(&self, command: ProtocolCommand) -> ProtocolCommandResult<()> {
        self.command_tx
            .send(command)
            .map_err(|_| "ACP protocol command channel is closed".to_string())
    }

    fn receive<T>(
        &self,
        response_rx: &mpsc::Receiver<ProtocolCommandResult<T>>,
    ) -> ProtocolCommandResult<T> {
        receive_response(response_rx, self.response_timeout)
    }
}

fn receive_response<T>(
    response_rx: &mpsc::Receiver<ProtocolCommandResult<T>>,
    response_timeout: Duration,
) -> ProtocolCommandResult<T> {
    response_rx
        .recv_timeout(response_timeout)
        .map_err(|error| match error {
            mpsc::RecvTimeoutError::Timeout => format!(
                "ACP protocol command loop did not answer within {} ms",
                response_timeout.as_millis()
            ),
            mpsc::RecvTimeoutError::Disconnected => {
                "ACP protocol command response channel is closed".to_string()
            }
        })?
}

#[cfg(test)]
mod tests;
