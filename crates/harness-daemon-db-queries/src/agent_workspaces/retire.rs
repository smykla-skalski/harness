use std::collections::BTreeSet;

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::shadow::{ShadowWorkspace, shadow_digest};

#[derive(Debug, FromRow)]
struct RetiredWorkspaceRow {
    workspace_id: String,
    daemon_id: String,
    project_scope_id: String,
    checkout_id: String,
    source_project_id: String,
    project_name: String,
    checkout_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    is_worktree: i64,
    worktree_name: Option<String>,
    availability: String,
    manifest_digest: String,
    created_at: String,
}

pub(super) async fn retire_deleted_legacy_correlations(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    source_project_ids: &[String],
    now: &str,
) -> Result<(), CliError> {
    let active_projects = source_project_ids.iter().collect::<BTreeSet<_>>();
    let queued_projects = query_as::<_, (String,)>(
        "SELECT project_id FROM agent_workspace_reconcile_queue ORDER BY project_id",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workspace reconcile queue: {error}")))?;
    for (project_id,) in queued_projects {
        if active_projects.contains(&project_id) {
            continue;
        }
        retire_project(transaction, daemon_id, &project_id, now).await?;
    }
    Ok(())
}

async fn retire_project(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    project_id: &str,
    now: &str,
) -> Result<(), CliError> {
    query(
        "DELETE FROM agent_workspace_legacy_sessions
         WHERE workspace_id IN (
             SELECT workspace_id FROM agent_workspaces
             WHERE daemon_id = ?1 AND source_project_id = ?2
         )",
    )
    .bind(daemon_id)
    .bind(project_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("retire workspace Session provenance: {error}")))?;
    query(
        "UPDATE agent_workspaces
         SET selected_legacy_session_id = NULL,
             orchestration_authority = 'no_owner',
             updated_at = ?3
         WHERE daemon_id = ?1 AND source_project_id = ?2",
    )
    .bind(daemon_id)
    .bind(project_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("retire workspace Session correlation: {error}")))?;
    refresh_retired_shadow_digests(transaction, daemon_id, project_id).await
}

async fn refresh_retired_shadow_digests(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    project_id: &str,
) -> Result<(), CliError> {
    let rows = query_as::<_, RetiredWorkspaceRow>(
        "SELECT workspace_id, daemon_id, project_scope_id, checkout_id,
                source_project_id, project_name, checkout_name, project_dir,
                repository_root, context_root, is_worktree, worktree_name,
                availability, manifest_digest, created_at
         FROM agent_workspaces
         WHERE daemon_id = ?1 AND source_project_id = ?2
         ORDER BY workspace_id",
    )
    .bind(daemon_id)
    .bind(project_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load retired workspace shadow: {error}")))?;
    for row in rows {
        let workspace_id = row.workspace_id.clone();
        let digest = shadow_digest(&row.into_shadow());
        query("UPDATE agent_workspaces SET shadow_digest = ?2 WHERE workspace_id = ?1")
            .bind(workspace_id)
            .bind(digest)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("refresh retired workspace shadow: {error}")))?;
    }
    Ok(())
}

impl RetiredWorkspaceRow {
    fn into_shadow(self) -> ShadowWorkspace {
        ShadowWorkspace {
            workspace_id: self.workspace_id,
            daemon_id: self.daemon_id,
            project_scope_id: self.project_scope_id,
            checkout_id: self.checkout_id,
            source_project_id: self.source_project_id,
            project_name: self.project_name,
            checkout_name: self.checkout_name,
            project_dir: self.project_dir,
            repository_root: self.repository_root,
            context_root: self.context_root,
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name,
            availability: self.availability,
            selected_legacy_session_id: None,
            manifest_digest: self.manifest_digest,
            orchestration_authority: "no_owner".to_string(),
            created_at: self.created_at,
            candidates: Vec::new(),
        }
    }
}

pub(super) async fn clear_reconcile_queue(
    transaction: &mut Transaction<'_, Sqlite>,
    active_project_ids: &[String],
) -> Result<(), CliError> {
    query(
        "DELETE FROM agent_workspace_reconcile_queue
         WHERE project_id IN (SELECT value FROM json_each(?1))
            OR NOT EXISTS (
                SELECT 1 FROM agent_workspaces
                WHERE source_project_id = agent_workspace_reconcile_queue.project_id
                  AND orchestration_authority = 'legacy_session'
            )",
    )
    .bind(
        serde_json::to_string(active_project_ids)
            .map_err(|error| db_error(format!("serialize active workspace projects: {error}")))?,
    )
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear workspace reconcile queue: {error}")))?;
    Ok(())
}
