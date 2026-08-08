use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_workspace::workspace::utc_now;
use sqlx::{Sqlite, Transaction, query};

use crate::agent_workspaces::availability::{RecordedCheckout, recorded_checkout_availability};
use crate::agent_workspaces::identity::digest_fields;
use crate::agent_workspaces::availability_label;
use crate::agent_workspaces::shadow::{ShadowWorkspace, shadow_digest};

use super::model::{ProvisionedWorkspaceCheckout, WorkspaceCheckoutRequest};

/// A workspace the daemon owns outright carries no legacy Session, so its
/// manifest is the identity triple alone. Reconciliation never rebuilds this
/// row from Session state, but it does recompute the shadow digest for every
/// workspace it sees, which is why the write below has to produce exactly the
/// digest `agent_workspaces::source` will recompute.
fn workspace_manifest_digest(daemon_id: &str, project_scope_id: &str, checkout_id: &str) -> String {
    digest_fields(["workspace-owned", daemon_id, project_scope_id, checkout_id])
}

pub(super) async fn provision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &WorkspaceCheckoutRequest,
) -> Result<ProvisionedWorkspaceCheckout, CliError> {
    let project = &request.project;
    let project_scope_id = project.summary_project_id();
    let checkout_id = project.checkout_id.clone();
    let workspace_id = format!(
        "agent-workspace-{}",
        digest_fields([
            request.daemon_id.as_str(),
            project_scope_id.as_str(),
            checkout_id.as_str()
        ])
    );
    let project_dir = project
        .project_dir
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    let repository_root = project
        .repository_root
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    let context_root = project.context_root.to_string_lossy().into_owned();
    let availability = recorded_checkout_availability(RecordedCheckout {
        project_dir: project_dir.as_deref(),
        repository_root: repository_root.as_deref(),
        is_worktree: project.is_worktree,
        worktree_name: project.worktree_name.as_deref(),
    })
    .map_err(|detail| db_error(format!("verify provisioned workspace checkout: {detail}")))?;
    let manifest_digest =
        workspace_manifest_digest(&request.daemon_id, &project_scope_id, &checkout_id);
    let now = utc_now();
    let created_at = existing_workspace_created_at(transaction, &workspace_id)
        .await?
        .unwrap_or_else(|| now.clone());
    let shadow = ShadowWorkspace {
        workspace_id: workspace_id.clone(),
        daemon_id: request.daemon_id.clone(),
        project_scope_id: project_scope_id.clone(),
        checkout_id: checkout_id.clone(),
        source_project_id: project.project_id.clone(),
        project_name: project.summary_project_name(),
        checkout_name: project.checkout_name.clone(),
        project_dir: project_dir.clone(),
        repository_root: repository_root.clone(),
        context_root: context_root.clone(),
        is_worktree: i64::from(project.is_worktree),
        worktree_name: project.worktree_name.clone(),
        availability: availability_label(availability).to_string(),
        selected_legacy_session_id: None,
        manifest_digest: manifest_digest.clone(),
        orchestration_authority: "workspace".to_string(),
        created_at: created_at.clone(),
        candidates: Vec::new(),
    };
    let shadow = shadow_digest(&shadow);

    query(
        "INSERT INTO agent_workspaces (
            workspace_id, daemon_id, project_scope_id, checkout_id, source_project_id,
            project_name, checkout_name, project_dir, repository_root, context_root,
            is_worktree, worktree_name, availability, selected_legacy_session_id,
            manifest_digest, shadow_digest, orchestration_authority, created_at, updated_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, NULL,
            ?14, ?15, 'workspace', ?16, ?17
         )
         ON CONFLICT(workspace_id) DO UPDATE SET
            source_project_id = excluded.source_project_id,
            project_name = excluded.project_name,
            checkout_name = excluded.checkout_name,
            project_dir = excluded.project_dir,
            repository_root = excluded.repository_root,
            context_root = excluded.context_root,
            is_worktree = excluded.is_worktree,
            worktree_name = excluded.worktree_name,
            availability = excluded.availability,
            manifest_digest = excluded.manifest_digest,
            shadow_digest = excluded.shadow_digest,
            orchestration_authority = 'workspace',
            updated_at = excluded.updated_at",
    )
    .bind(&workspace_id)
    .bind(&request.daemon_id)
    .bind(&project_scope_id)
    .bind(&checkout_id)
    .bind(&project.project_id)
    .bind(project.summary_project_name())
    .bind(&project.checkout_name)
    .bind(&project_dir)
    .bind(&repository_root)
    .bind(&context_root)
    .bind(i64::from(project.is_worktree))
    .bind(&project.worktree_name)
    .bind(availability_label(availability))
    .bind(&manifest_digest)
    .bind(&shadow)
    .bind(&created_at)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("provision durable agent workspace: {error}")))?;

    query(
        "INSERT INTO agent_workspace_teams (
            workspace_id, authority, selected_legacy_session_id, selected_lifecycle,
            leader_member_id, source_revision, reconciled_revision, shadow_digest,
            created_at, updated_at
         ) VALUES (?1, 'workspace', NULL, NULL, NULL, 1, 1, '', ?2, ?3)
         ON CONFLICT(workspace_id) DO NOTHING",
    )
    .bind(&workspace_id)
    .bind(&created_at)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("provision durable agent team: {error}")))?;

    // Idempotent on the reserved id: a preparation that crashed between the
    // checkout and its commit retries with the same working-copy id, and must
    // find one row rather than trip the live-path index with a second.
    query(
        "INSERT INTO agent_working_copies (
            working_copy_id, workspace_id, origin_path, project_name, worktree_path,
            branch_ref, status, released_reason, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', NULL, ?7, ?7)
         ON CONFLICT(working_copy_id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            origin_path = excluded.origin_path,
            project_name = excluded.project_name,
            worktree_path = excluded.worktree_path,
            branch_ref = excluded.branch_ref,
            status = 'active',
            released_reason = NULL,
            updated_at = excluded.updated_at",
    )
    .bind(&request.working_copy_id)
    .bind(&workspace_id)
    .bind(&request.origin_path)
    .bind(&request.project_name)
    .bind(&request.worktree_path)
    .bind(&request.branch_ref)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record durable agent working copy: {error}")))?;

    Ok(ProvisionedWorkspaceCheckout {
        workspace_id,
        working_copy_id: request.working_copy_id.clone(),
        worktree_path: request.worktree_path.clone(),
        branch_ref: request.branch_ref.clone(),
    })
}

/// Keeps `created_at` stable across a re-provision so the shadow digest this
/// writes matches the one reconciliation recomputes from the stored row.
async fn existing_workspace_created_at(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<Option<String>, CliError> {
    sqlx::query_as::<_, (String,)>("SELECT created_at FROM agent_workspaces WHERE workspace_id = ?1")
        .bind(workspace_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map(|row| row.map(|row| row.0))
        .map_err(|error| db_error(format!("load provisioned workspace timestamp: {error}")))
}
