use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::activity::{
    AgentWorkspaceActivityWindowResponse, AgentWorkspaceMemberActivityResponse,
    AgentWorkspaceSignalRecord,
};
use harness_protocol::timeline::TimelineWindowRequest;
use sqlx::{Sqlite, Transaction};

mod reads;
mod reconcile;
mod signals;
mod types;

pub use types::{AgentWorkspaceSignalAcknowledgment, AgentWorkspaceSignalTarget};

pub trait AsyncAgentWorkspaceActivityQueries: Send + Sync {
    /// Reconcile legacy observation sources and return a workspace-owned timeline window.
    ///
    /// # Errors
    /// Returns [`CliError`] when the workspace, source mapping, or durable ledger is invalid.
    fn load_agent_workspace_activity(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        request: &TimelineWindowRequest,
    ) -> impl Future<Output = Result<AgentWorkspaceActivityWindowResponse, CliError>> + Send;

    /// Reconcile and load one durable member's activity, transcript, and signals.
    ///
    /// # Errors
    /// Returns [`CliError`] when the workspace/member scope is invalid or persistence fails.
    fn load_agent_workspace_member_activity(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
    ) -> impl Future<Output = Result<AgentWorkspaceMemberActivityResponse, CliError>> + Send;

    /// Resolve one durable member to the runtime and working-copy coordinates used for delivery.
    ///
    /// # Errors
    /// Returns [`CliError`] when the scope is invalid or the member cannot receive signals.
    fn load_agent_workspace_signal_target(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
    ) -> impl Future<Output = Result<AgentWorkspaceSignalTarget, CliError>> + Send;

    /// Persist a workspace-owned signal before runtime delivery.
    ///
    /// # Errors
    /// Returns [`CliError`] when the scope is invalid or the signal cannot be stored.
    fn insert_agent_workspace_signal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        runtime: &str,
        signal: &harness_protocol::agent::Signal,
    ) -> impl Future<Output = Result<AgentWorkspaceSignalRecord, CliError>> + Send;

    /// Record one durable signal acknowledgment.
    ///
    /// # Errors
    /// Returns [`CliError`] when the signal does not belong to the requested member or storage fails.
    fn acknowledge_agent_workspace_signal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        acknowledgment: &AgentWorkspaceSignalAcknowledgment,
    ) -> impl Future<Output = Result<AgentWorkspaceSignalRecord, CliError>> + Send;
}

impl AsyncAgentWorkspaceActivityQueries for AsyncDaemonDb {
    async fn load_agent_workspace_activity(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        request: &TimelineWindowRequest,
    ) -> Result<AgentWorkspaceActivityWindowResponse, CliError> {
        let mut transaction = begin_activity_transaction(self, "activity read").await?;
        ensure_workspace_scope(&mut transaction, daemon_id, workspace_id).await?;
        reconcile::reconcile_one(&mut transaction, workspace_id).await?;
        let response = reads::load_activity_window(&mut transaction, workspace_id, request).await?;
        commit_activity_transaction(transaction, "activity read").await?;
        Ok(response)
    }

    async fn load_agent_workspace_member_activity(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
    ) -> Result<AgentWorkspaceMemberActivityResponse, CliError> {
        let mut transaction = begin_activity_transaction(self, "member activity read").await?;
        ensure_workspace_scope(&mut transaction, daemon_id, workspace_id).await?;
        reconcile::reconcile_one(&mut transaction, workspace_id).await?;
        let response =
            reads::load_member_activity(&mut transaction, workspace_id, member_id).await?;
        commit_activity_transaction(transaction, "member activity read").await?;
        Ok(response)
    }

    async fn load_agent_workspace_signal_target(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
    ) -> Result<AgentWorkspaceSignalTarget, CliError> {
        let mut transaction = begin_activity_transaction(self, "signal target read").await?;
        ensure_workspace_scope(&mut transaction, daemon_id, workspace_id).await?;
        reconcile::reconcile_one(&mut transaction, workspace_id).await?;
        let target = signals::load_signal_target(&mut transaction, workspace_id, member_id).await?;
        commit_activity_transaction(transaction, "signal target read").await?;
        Ok(target)
    }

    async fn insert_agent_workspace_signal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        runtime: &str,
        signal: &harness_protocol::agent::Signal,
    ) -> Result<AgentWorkspaceSignalRecord, CliError> {
        let mut transaction = begin_activity_transaction(self, "signal insert").await?;
        ensure_workspace_scope(&mut transaction, daemon_id, workspace_id).await?;
        let record =
            signals::insert_signal(&mut transaction, workspace_id, member_id, runtime, signal)
                .await?;
        commit_activity_transaction(transaction, "signal insert").await?;
        Ok(record)
    }

    async fn acknowledge_agent_workspace_signal(
        &self,
        daemon_id: &str,
        workspace_id: &str,
        member_id: &str,
        acknowledgment: &AgentWorkspaceSignalAcknowledgment,
    ) -> Result<AgentWorkspaceSignalRecord, CliError> {
        let mut transaction = begin_activity_transaction(self, "signal acknowledgment").await?;
        ensure_workspace_scope(&mut transaction, daemon_id, workspace_id).await?;
        let record = signals::acknowledge_signal(
            &mut transaction,
            workspace_id,
            member_id,
            &acknowledgment.signal_id,
            acknowledgment.result,
            acknowledgment.details.as_deref(),
            acknowledgment.acknowledged_at.as_deref(),
        )
        .await?;
        commit_activity_transaction(transaction, "signal acknowledgment").await?;
        Ok(record)
    }
}

async fn begin_activity_transaction<'a>(
    db: &'a AsyncDaemonDb,
    operation: &str,
) -> Result<Transaction<'a, Sqlite>, CliError> {
    db.pool()
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(|error| db_error(format!("begin agent workspace {operation}: {error}")))
}

async fn commit_activity_transaction(
    transaction: Transaction<'_, Sqlite>,
    operation: &str,
) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit agent workspace {operation}: {error}")))
}

async fn ensure_workspace_scope(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    workspace_id: &str,
) -> Result<(), CliError> {
    let exists = sqlx::query_scalar::<_, i64>(
        "SELECT EXISTS (
            SELECT 1 FROM agent_workspaces workspace
            JOIN agent_workspace_activity_state activity
              ON activity.workspace_id = workspace.workspace_id
            JOIN agent_workspace_teams team
              ON team.workspace_id = workspace.workspace_id
            WHERE workspace.daemon_id = ?1 AND workspace.workspace_id = ?2
              AND team.source_revision = team.reconciled_revision
         )",
    )
    .bind(daemon_id.trim())
    .bind(workspace_id.trim())
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify agent workspace activity scope: {error}")))?;
    if exists == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "durable agent workspace '{workspace_id}' was not found"
        )))
    }
}
