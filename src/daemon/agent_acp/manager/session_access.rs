use std::sync::Arc;

use super::service;
use super::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpPermissionBatch, AcpPermissionDecision,
    ActiveAcpSession,
};
use crate::errors::{CliError, CliErrorKind};

impl AcpAgentManagerHandle {
    /// Resolve a pending ACP permission batch and return the updated snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ACP session or permission batch is unknown.
    pub fn resolve_permission_batch(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        if service::sandboxed_from_env() {
            return self.resolve_permission_batch_via_bridge(acp_id, batch_id, decision);
        }
        let session = self.session(acp_id)?;
        if !session.resolve_permission_batch(batch_id, decision) {
            return Err(CliErrorKind::session_not_active(format!(
                "permission_batch_stale: ACP permission batch '{batch_id}' is not pending for session '{acp_id}'"
            ))
            .into());
        }
        let snapshot = session.snapshot_with_live_counts();
        self.broadcast("acp_permission_batch_resolved", &snapshot);
        Ok(snapshot)
    }

    #[must_use]
    /// Return the number of pending ACP permission prompts for one ACP session.
    pub fn pending_permission_count(&self, acp_id: &str) -> Option<usize> {
        if service::sandboxed_from_env() {
            return self.pending_permission_count_via_bridge(acp_id);
        }
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_count())
    }

    #[must_use]
    /// Return the queued ACP permission batches for one ACP session.
    pub fn pending_permission_batches(&self, acp_id: &str) -> Option<Vec<AcpPermissionBatch>> {
        if service::sandboxed_from_env() {
            return self.pending_permission_batches_via_bridge(acp_id);
        }
        let sessions = self.state.sessions.lock().ok()?;
        sessions
            .get(acp_id)
            .map(|session| session.pending_permission_batches())
    }

    pub(super) fn session(&self, acp_id: &str) -> Result<Arc<ActiveAcpSession>, CliError> {
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .get(acp_id)
            .cloned()
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!("ACP session '{acp_id}' not found")).into()
            })
    }

    pub(super) fn sessions_for(&self, session_id: &str) -> Vec<Arc<ActiveAcpSession>> {
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .filter(|session| session.session_id() == session_id)
            .cloned()
            .collect()
    }
}
