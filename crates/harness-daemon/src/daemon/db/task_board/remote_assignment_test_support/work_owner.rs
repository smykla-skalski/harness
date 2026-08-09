use crate::daemon::db::AsyncDaemonDb;

use super::NOW;

pub(super) async fn seed_remote_item_owner(
    db: &AsyncDaemonDb,
    label: &str,
) -> (String, String, String) {
    let workspace_id = format!("source-workspace-{label}");
    let working_copy_id = format!("source-copy-{label}");
    let work_item_id = format!("source-work-item-{label}");
    let source_path = format!("/tmp/source-checkout-{label}");
    sqlx::query(
        "INSERT INTO agent_workspaces (
             workspace_id, daemon_id, project_scope_id, checkout_id, source_project_id,
             project_name, checkout_name, project_dir, repository_root, context_root,
             is_worktree, availability, manifest_digest, shadow_digest,
             orchestration_authority, created_at, updated_at
         ) VALUES (?1, 'source-daemon', ?1, ?2, ?1, 'harness', ?2, ?3, ?3, ?3,
                   1, 'available', ?1, ?1, 'workspace', ?4, ?4)",
    )
    .bind(&workspace_id)
    .bind(&working_copy_id)
    .bind(&source_path)
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("seed remote source workspace");
    sqlx::query(
        "INSERT INTO agent_workspace_teams (
             workspace_id, authority, source_revision, reconciled_revision,
             shadow_digest, created_at, updated_at
         ) VALUES (?1, 'workspace', 1, 1, ?1, ?2, ?2)",
    )
    .bind(&workspace_id)
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("seed remote source team");
    sqlx::query(
        "INSERT INTO agent_working_copies (
             working_copy_id, workspace_id, origin_path, project_name, worktree_path,
             branch_ref, status, created_at, updated_at
         ) VALUES (?1, ?2, ?3, 'harness', ?3, ?4, 'active', ?5, ?5)",
    )
    .bind(&working_copy_id)
    .bind(&workspace_id)
    .bind(&source_path)
    .bind(format!("harness/{working_copy_id}"))
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("seed remote source working copy");
    (workspace_id, working_copy_id, work_item_id)
}
