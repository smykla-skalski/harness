use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::summaries::AgentWorkspaceListResponse;

use crate::daemon::db::prelude::*;
use crate::daemon::{db_handle::AsyncDaemonDbHandle, state};

/// Reconcile and list durable agent workspaces for this daemon identity.
///
/// # Errors
/// Returns [`CliError`] when daemon identity or workspace persistence is unavailable.
pub(crate) async fn list_agent_workspaces_async(
    db: &AsyncDaemonDbHandle,
) -> Result<AgentWorkspaceListResponse, CliError> {
    let identity = tokio::task::spawn_blocking(state::reported_daemon_identity)
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("join daemon identity read: {error}")))??
        .ok_or_else(|| CliErrorKind::workflow_io("daemon identity is unavailable"))?;
    db.reconcile_agent_workspaces(&identity.daemon_id).await
}
