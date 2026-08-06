use std::collections::BTreeMap;
use std::future::Future;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{AgentWorkspaceTeamConflict, AgentWorkspaceTeamResponse};
use sqlx::{Sqlite, Transaction, query_scalar};

mod evidence;
mod identity;
mod model;
mod operation_preflight;
mod operation_rules;
mod operations;
mod persist;
mod plan;
mod response;
mod source;
mod status;
mod validation;

use persist::{finalize_detached_team, persist_team_plan, validate_team_shadow};
use plan::build_team_plan;
use response::load_team_response;
use source::load_workspace_sources;

pub use operation_preflight::AsyncAgentWorkspaceTeamOperationPreflightQueries;
pub use operations::AsyncAgentWorkspaceTeamOperationQueries;

#[cfg(test)]
mod tests;

pub trait AsyncAgentWorkspaceTeamQueries: Send + Sync {
    /// Reconcile and return the durable team for one workspace.
    ///
    /// # Errors
    /// Returns [`CliError`] when the workspace or its verified sources cannot be read.
    fn reconcile_agent_workspace_team(
        &self,
        daemon_id: &str,
        workspace_id: &str,
    ) -> impl Future<Output = Result<AgentWorkspaceTeamResponse, CliError>> + Send;
}

impl AsyncAgentWorkspaceTeamQueries for AsyncDaemonDb {
    async fn reconcile_agent_workspace_team(
        &self,
        daemon_id: &str,
        workspace_id: &str,
    ) -> Result<AgentWorkspaceTeamResponse, CliError> {
        let daemon_id = required_identifier(daemon_id, "daemon id")?;
        let workspace_id = required_identifier(workspace_id, "workspace id")?;
        let mut transaction = self
            .pool()
            .begin_with("BEGIN IMMEDIATE")
            .await
            .map_err(|error| db_error(format!("begin agent team reconciliation: {error}")))?;
        ensure_workspace(&mut transaction, daemon_id, workspace_id).await?;
        let mut conflicts =
            reconcile_workspace_teams(&mut transaction, daemon_id, Some(workspace_id))
                .await?
                .remove(workspace_id)
                .unwrap_or_default();
        if conflicts.is_empty()
            && let Some(conflict) = validate_team_shadow(&mut transaction, workspace_id).await?
        {
            conflicts.push(conflict);
        }
        let response = load_team_response(&mut transaction, workspace_id, conflicts).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit agent team reconciliation: {error}")))?;
        Ok(response)
    }
}

pub(crate) async fn reconcile_workspace_teams(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    workspace_id: Option<&str>,
) -> Result<BTreeMap<String, Vec<AgentWorkspaceTeamConflict>>, CliError> {
    let sources = load_workspace_sources(transaction, daemon_id, workspace_id).await?;
    let now = harness_workspace::workspace::utc_now();
    let mut conflicts = BTreeMap::new();
    for source in sources {
        let id = source.workspace.workspace_id.clone();
        if source.workspace.stored_shadow_digest.as_deref() == Some("") {
            if source.workspace.selected_legacy_session_id.is_none() {
                finalize_detached_team(transaction, &id).await?;
                continue;
            }
        } else if let Some(conflict) = validate_team_shadow(transaction, &id).await? {
            conflicts.entry(id).or_insert_with(Vec::new).push(conflict);
            continue;
        }
        if source.workspace.source_revision.is_some()
            && source.workspace.source_revision == source.workspace.reconciled_revision
        {
            continue;
        }
        match build_team_plan(&source, &now) {
            Ok(Some(plan)) => persist_team_plan(transaction, &plan).await?,
            Ok(None) => finalize_detached_team(transaction, &id).await?,
            Err(conflict) => conflicts.entry(id).or_insert_with(Vec::new).push(conflict),
        }
    }
    Ok(conflicts)
}

async fn ensure_workspace(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    workspace_id: &str,
) -> Result<(), CliError> {
    let exists = query_scalar::<_, i64>(
        "SELECT EXISTS (
            SELECT 1 FROM agent_workspaces
            WHERE daemon_id = ?1 AND workspace_id = ?2
         )",
    )
    .bind(daemon_id)
    .bind(workspace_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify durable agent workspace: {error}")))?;
    if exists == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "durable agent workspace '{workspace_id}' was not found"
        )))
    }
}

fn required_identifier<'a>(value: &'a str, label: &str) -> Result<&'a str, CliError> {
    let value = value.trim();
    if value.is_empty() {
        Err(db_error(format!("reconcile agent team: {label} is empty")))
    } else {
        Ok(value)
    }
}
