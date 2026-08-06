use std::future::Future;

use harness_daemon_db_core::AsyncDaemonDb;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::AgentWorkspaceListResponse;

mod availability;
mod candidate;
mod identity;
mod persist;
mod preflight;
mod retire;
mod shadow;
mod source;

#[cfg(test)]
mod tests;

use persist::{load_response, persist_preflight};
use preflight::preflight;
use source::{load_candidates, load_existing_workspace_sources};

pub trait AsyncAgentWorkspaceQueries: Send + Sync {
    /// Reconcile legacy Session owners into durable workspace identity and return the verified view.
    ///
    /// # Errors
    /// Returns [`CliError`] when the source snapshot or atomic reconciliation cannot be read.
    fn reconcile_agent_workspaces(
        &self,
        daemon_id: &str,
    ) -> impl Future<Output = Result<AgentWorkspaceListResponse, CliError>> + Send;
}

impl AsyncAgentWorkspaceQueries for AsyncDaemonDb {
    async fn reconcile_agent_workspaces(
        &self,
        daemon_id: &str,
    ) -> Result<AgentWorkspaceListResponse, CliError> {
        let daemon_id = daemon_id.trim();
        if daemon_id.is_empty() {
            return Err(harness_daemon_db_core::db_error(
                "reconcile agent workspaces: daemon id is empty",
            ));
        }

        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| {
                harness_daemon_db_core::db_error(format!(
                    "begin agent workspace reconciliation: {error}"
                ))
            })?;
        let candidates = load_candidates(&mut transaction).await?;
        let existing = load_existing_workspace_sources(&mut transaction, daemon_id).await?;
        let result = preflight(daemon_id, candidates, &existing);
        persist_preflight(&mut transaction, &result).await?;
        let response = load_response(&mut transaction, daemon_id, &result).await?;
        transaction.commit().await.map_err(|error| {
            harness_daemon_db_core::db_error(format!(
                "commit agent workspace reconciliation: {error}"
            ))
        })?;
        Ok(response)
    }
}
