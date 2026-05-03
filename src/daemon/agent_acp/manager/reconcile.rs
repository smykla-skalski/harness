use serde::{Deserialize, Serialize};

use super::{AcpAgentInspectResponse, AcpAgentManagerHandle, AcpAgentSnapshot};
use crate::errors::CliError;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AcpAgentReconcileResponse {
    pub inspect: AcpAgentInspectResponse,
    pub agents: Vec<AcpAgentSnapshot>,
}

impl AcpAgentManagerHandle {
    /// Load a bridge-sized ACP snapshot with both inspect rows and live session
    /// snapshots from one refresh pass.
    ///
    /// # Errors
    /// Returns [`CliError`] when the live session registry is unavailable.
    pub(crate) fn reconcile_snapshot(&self) -> Result<AcpAgentReconcileResponse, CliError> {
        let sessions = self.sessions_guard()?.values().cloned().collect::<Vec<_>>();
        let mut inspect_agents = Vec::with_capacity(sessions.len());
        let mut snapshots = Vec::with_capacity(sessions.len());
        for session in sessions {
            let snapshot = self.refresh_session_snapshot(&session)?;
            if snapshot.status.is_disconnected() {
                continue;
            }
            inspect_agents.push(session.inspect_snapshot_for(&snapshot));
            snapshots.push(snapshot);
        }
        inspect_agents.sort_by(|a, b| {
            b.last_update_at
                .cmp(&a.last_update_at)
                .then_with(|| a.acp_id.cmp(&b.acp_id))
        });
        snapshots.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.acp_id.cmp(&b.acp_id))
        });
        Ok(AcpAgentReconcileResponse {
            inspect: AcpAgentInspectResponse {
                agents: inspect_agents,
                available: true,
                issue_message: None,
            },
            agents: snapshots,
        })
    }
}
