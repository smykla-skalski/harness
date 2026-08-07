//! Workspace-owned checkouts and the managed workers that run in them.
//!
//! `agent_workspaces` reconciles legacy Sessions into durable workspace
//! identity. This module is the other direction: it provisions a workspace and
//! its checkout for work that never had a Session, which is what task-board
//! dispatch needs once it stops creating one.

use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_workspace::workspace::utc_now;
use sqlx::{query, query_as};

mod members;
mod model;
mod provision;

#[cfg(test)]
mod tests;

pub use model::{
    AgentWorkingCopy, ProvisionedWorkspaceCheckout, WorkspaceCheckoutRequest,
    WorkspaceManagedAgentKind, WorkspaceMemberRegistration,
};

pub trait AsyncAgentWorkingCopyQueries: Send + Sync {
    /// Record a checkout the daemon created, its owning workspace, and that
    /// workspace's team, in one transaction.
    ///
    /// # Errors
    /// Returns [`CliError`] when the checkout cannot be verified or the rows
    /// cannot be written.
    fn provision_agent_workspace_checkout(
        &self,
        request: &WorkspaceCheckoutRequest,
    ) -> impl Future<Output = Result<ProvisionedWorkspaceCheckout, CliError>> + Send;

    /// Read a recorded checkout back, including released ones so compensation
    /// can tell "already cleaned up" from "never existed".
    ///
    /// # Errors
    /// Returns [`CliError`] when the row cannot be read.
    fn load_agent_working_copy(
        &self,
        working_copy_id: &str,
    ) -> impl Future<Output = Result<Option<AgentWorkingCopy>, CliError>> + Send;

    /// Mark a checkout released after its directory is gone. Returns whether
    /// this call was the one that released it.
    ///
    /// # Errors
    /// Returns [`CliError`] when the row cannot be written.
    fn release_agent_working_copy(
        &self,
        working_copy_id: &str,
        reason: &str,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;

    /// Join a managed worker to its workspace team, returning the member id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the member cannot be written.
    fn register_workspace_managed_member(
        &self,
        registration: &WorkspaceMemberRegistration,
    ) -> impl Future<Output = Result<String, CliError>> + Send;

    /// Record that a managed worker's runtime stopped, leaving its membership
    /// in place.
    ///
    /// # Errors
    /// Returns [`CliError`] when the member cannot be written.
    fn record_workspace_member_runtime_stop(
        &self,
        workspace_id: &str,
        member_id: &str,
        reason: &str,
    ) -> impl Future<Output = Result<(), CliError>> + Send;
}

impl AsyncAgentWorkingCopyQueries for AsyncDaemonDb {
    async fn provision_agent_workspace_checkout(
        &self,
        request: &WorkspaceCheckoutRequest,
    ) -> Result<ProvisionedWorkspaceCheckout, CliError> {
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| db_error(format!("begin workspace checkout provision: {error}")))?;
        let provisioned = provision::provision_in_tx(&mut transaction, request).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit workspace checkout provision: {error}")))?;
        Ok(provisioned)
    }

    async fn load_agent_working_copy(
        &self,
        working_copy_id: &str,
    ) -> Result<Option<AgentWorkingCopy>, CliError> {
        query_as::<_, (String, String, String, String, String, String, String)>(
            "SELECT working_copy_id, workspace_id, origin_path, project_name,
                    worktree_path, branch_ref, status
             FROM agent_working_copies WHERE working_copy_id = ?1",
        )
        .bind(working_copy_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load durable agent working copy: {error}")))
        .map(|row| {
            row.map(|row| AgentWorkingCopy {
                working_copy_id: row.0,
                workspace_id: row.1,
                origin_path: row.2,
                project_name: row.3,
                worktree_path: row.4,
                branch_ref: row.5,
                released: row.6 == "released",
            })
        })
    }

    async fn release_agent_working_copy(
        &self,
        working_copy_id: &str,
        reason: &str,
    ) -> Result<bool, CliError> {
        let released = query(
            "UPDATE agent_working_copies
             SET status = 'released', released_reason = ?2, updated_at = ?3
             WHERE working_copy_id = ?1 AND status = 'active'",
        )
        .bind(working_copy_id)
        .bind(reason)
        .bind(utc_now())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("release durable agent working copy: {error}")))?;
        Ok(released.rows_affected() > 0)
    }

    async fn register_workspace_managed_member(
        &self,
        registration: &WorkspaceMemberRegistration,
    ) -> Result<String, CliError> {
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| db_error(format!("begin workspace member join: {error}")))?;
        let member_id = members::register_in_tx(&mut transaction, registration).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit workspace member join: {error}")))?;
        Ok(member_id)
    }

    async fn record_workspace_member_runtime_stop(
        &self,
        workspace_id: &str,
        member_id: &str,
        reason: &str,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| db_error(format!("begin workspace member stop: {error}")))?;
        members::record_runtime_stop_in_tx(&mut transaction, workspace_id, member_id, reason)
            .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit workspace member stop: {error}")))?;
        Ok(())
    }
}
