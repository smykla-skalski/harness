use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::session::ManagedAgentKind;

use super::operations::{MemberLocator, resolve_or_reconcile_location};

pub trait AsyncAgentWorkspaceTeamOperationPreflightQueries: Send + Sync {
    /// Reconcile and verify that a managed runtime can record an operation.
    ///
    /// # Errors
    /// Returns [`CliError`] when identity is ambiguous or its team cannot reconcile.
    fn prepare_agent_workspace_runtime_operation(
        &self,
        daemon_id: &str,
        kind: ManagedAgentKind,
        managed_agent_id: &str,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;

    /// Reconcile and verify that a legacy Session member can record removal.
    ///
    /// # Errors
    /// Returns [`CliError`] when identity is ambiguous or its team cannot reconcile.
    fn prepare_agent_workspace_membership_operation(
        &self,
        daemon_id: &str,
        session_id: &str,
        agent_id: &str,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;
}

impl AsyncAgentWorkspaceTeamOperationPreflightQueries for AsyncDaemonDb {
    async fn prepare_agent_workspace_runtime_operation(
        &self,
        daemon_id: &str,
        kind: ManagedAgentKind,
        managed_agent_id: &str,
    ) -> Result<bool, CliError> {
        prepare_operation(
            self,
            MemberLocator::Managed {
                daemon_id,
                kind,
                id: managed_agent_id,
            },
        )
        .await
    }

    async fn prepare_agent_workspace_membership_operation(
        &self,
        daemon_id: &str,
        session_id: &str,
        agent_id: &str,
    ) -> Result<bool, CliError> {
        prepare_operation(
            self,
            MemberLocator::Legacy {
                daemon_id,
                session_id,
                agent_id,
            },
        )
        .await
    }
}

async fn prepare_operation(
    db: &AsyncDaemonDb,
    locator: MemberLocator<'_>,
) -> Result<bool, CliError> {
    let mut transaction = db
        .pool()
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(|error| db_error(format!("begin durable operation preflight: {error}")))?;
    let ready = resolve_or_reconcile_location(&mut transaction, locator)
        .await?
        .is_some();
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit durable operation preflight: {error}")))?;
    Ok(ready)
}
