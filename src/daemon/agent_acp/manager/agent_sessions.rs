//! Manager entry points for the agent's own session store.
//!
//! Each call is capability-gated down in the protocol layer, so failures here
//! surface as a plain workflow error naming the agent rather than a protocol
//! type leaking into the daemon surface.

use std::path::PathBuf;

use super::{AcpAgentManagerHandle, AcpSessionListPage};
use crate::errors::{CliError, CliErrorKind};

impl AcpAgentManagerHandle {
    /// List the sessions the agent itself knows about.
    ///
    /// These ids belong to the agent, not to harness, so the result is display
    /// data rather than a source of harness session state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown, the capability is
    /// missing, or the agent rejects the call.
    pub fn list_agent_sessions(
        &self,
        acp_id: &str,
        cwd: Option<PathBuf>,
        cursor: Option<String>,
    ) -> Result<AcpSessionListPage, CliError> {
        let session = self.session(acp_id)?;
        session.list_sessions(cwd, cursor).map_err(|error| {
            CliErrorKind::workflow_io(format!("ACP session list for '{acp_id}': {error}")).into()
        })
    }

    /// Ask the agent to close one of its sessions.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown, the capability is
    /// missing, or the agent rejects the call.
    pub fn close_agent_session(
        &self,
        acp_id: &str,
        agent_session_id: &str,
    ) -> Result<(), CliError> {
        let session = self.session(acp_id)?;
        session.close_session(agent_session_id).map_err(|error| {
            CliErrorKind::workflow_io(format!("ACP session close for '{acp_id}': {error}")).into()
        })
    }

    /// Ask the agent to delete one of its sessions.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session is unknown, the capability is
    /// missing, or the agent rejects the call.
    pub fn delete_agent_session(
        &self,
        acp_id: &str,
        agent_session_id: &str,
    ) -> Result<(), CliError> {
        let session = self.session(acp_id)?;
        session.delete_session(agent_session_id).map_err(|error| {
            CliErrorKind::workflow_io(format!("ACP session delete for '{acp_id}': {error}")).into()
        })
    }
}
