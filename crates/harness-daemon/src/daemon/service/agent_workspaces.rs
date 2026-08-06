use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::summaries::AgentWorkspaceMemberOperationOutcome;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceConflict, AgentWorkspaceListResponse, AgentWorkspaceTeamResponse,
};
use harness_protocol::session::ManagedAgentKind;
use harness_protocol::session::SessionState;
use harness_protocol::timeline::TimelineWindowRequest;
use rusqlite::{OptionalExtension, TransactionBehavior};
use sqlx::{query, query_as, query_scalar};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::prelude::*;
use crate::daemon::{db_handle::AsyncDaemonDbHandle, state};
use crate::daemon::{db_handle::DaemonDbOwnedHandle, db_open::AsyncDaemonDbConnect};

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

/// Reconcile and return the durable team for one workspace.
///
/// # Errors
/// Returns [`CliError`] when daemon identity, workspace persistence, or source verification fails.
pub(crate) async fn get_agent_workspace_team_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
) -> Result<AgentWorkspaceTeamResponse, CliError> {
    let identity = tokio::task::spawn_blocking(state::reported_daemon_identity)
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("join daemon identity read: {error}")))??
        .ok_or_else(|| CliErrorKind::workflow_io("daemon identity is unavailable"))?;
    let workspaces = db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    ensure_workspace_reconciliation_unblocked(db, &workspaces, &identity.daemon_id, workspace_id)
        .await?;
    db.reconcile_agent_workspace_team(&identity.daemon_id, workspace_id)
        .await
}

pub(crate) async fn prepare_agent_workspace_operation_async(
    db: &AsyncDaemonDbHandle,
    kind: ManagedAgentKind,
    managed_agent_id: &str,
) -> Result<String, CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    let workspaces = db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    ensure_runtime_reconciliation_unblocked(
        db,
        &workspaces,
        &identity.daemon_id,
        kind,
        managed_agent_id,
    )
    .await?;
    if !db
        .prepare_agent_workspace_runtime_operation(&identity.daemon_id, kind, managed_agent_id)
        .await?
    {
        return Err(CliErrorKind::workflow_io(format!(
            "durable agent identity '{managed_agent_id}' was not found"
        ))
        .into());
    }
    Ok(identity.daemon_id)
}

pub(crate) async fn prepare_agent_workspace_membership_operation_async(
    db: &AsyncDaemonDbHandle,
    session_id: &str,
    agent_id: &str,
) -> Result<String, CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    let workspaces = db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    if let Some(conflict) = workspaces.conflicts.iter().find(|conflict| {
        conflict
            .legacy_session_ids
            .iter()
            .any(|candidate| candidate == session_id)
    }) {
        return Err(reconciliation_conflict_error(
            "Session membership",
            session_id,
            conflict,
        ));
    }
    if !db
        .prepare_agent_workspace_membership_operation(&identity.daemon_id, session_id, agent_id)
        .await?
    {
        return Err(CliErrorKind::workflow_io(format!(
            "durable agent membership '{session_id}/{agent_id}' was not found"
        ))
        .into());
    }
    Ok(identity.daemon_id)
}

pub(crate) async fn remove_agent_workspace_member_async(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
) -> Result<AgentWorkspaceTeamResponse, CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    let workspaces = db.reconcile_agent_workspaces(&identity.daemon_id).await?;
    ensure_workspace_reconciliation_unblocked(db, &workspaces, &identity.daemon_id, workspace_id)
        .await?;
    let recorded = db
        .record_agent_workspace_member_removal(
            &identity.daemon_id,
            workspace_id,
            member_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await?;
    if !recorded {
        return Err(CliErrorKind::workflow_io(format!(
            "durable agent member '{member_id}' was not found in workspace '{workspace_id}'"
        ))
        .into());
    }
    db.reconcile_agent_workspace_team(&identity.daemon_id, workspace_id)
        .await
}

async fn ensure_workspace_reconciliation_unblocked(
    db: &AsyncDaemonDbHandle,
    response: &AgentWorkspaceListResponse,
    daemon_id: &str,
    workspace_id: &str,
) -> Result<(), CliError> {
    let Some((project_scope_id, checkout_id)) = query_as::<_, (String, String)>(
        "SELECT project_scope_id, checkout_id
         FROM agent_workspaces WHERE daemon_id = ?1 AND workspace_id = ?2",
    )
    .bind(daemon_id)
    .bind(workspace_id)
    .fetch_optional(db.pool())
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("load durable workspace conflict scope: {error}"))
    })?
    else {
        return Ok(());
    };
    let legacy_session_ids = query_scalar::<_, String>(
        "SELECT session_id FROM agent_workspace_legacy_sessions
         WHERE workspace_id = ?1 ORDER BY session_id",
    )
    .bind(workspace_id)
    .fetch_all(db.pool())
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "load durable workspace conflict provenance: {error}"
        ))
    })?;
    if let Some(conflict) = matching_workspace_conflict(
        response,
        &project_scope_id,
        &checkout_id,
        &legacy_session_ids,
    ) {
        return Err(reconciliation_conflict_error(
            "durable workspace",
            workspace_id,
            conflict,
        ));
    }
    Ok(())
}

async fn ensure_runtime_reconciliation_unblocked(
    db: &AsyncDaemonDbHandle,
    response: &AgentWorkspaceListResponse,
    daemon_id: &str,
    kind: ManagedAgentKind,
    managed_agent_id: &str,
) -> Result<(), CliError> {
    let workspace_ids = query_scalar::<_, String>(
        "SELECT DISTINCT member.workspace_id
         FROM agent_workspace_members member
         JOIN agent_workspaces workspace ON workspace.workspace_id = member.workspace_id
         WHERE workspace.daemon_id = ?1
           AND member.managed_agent_kind = ?2 AND member.managed_agent_id = ?3",
    )
    .bind(daemon_id)
    .bind(managed_kind_label(kind))
    .bind(managed_agent_id)
    .fetch_all(db.pool())
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("load durable runtime conflict scope: {error}"))
    })?;
    for workspace_id in workspace_ids {
        ensure_workspace_reconciliation_unblocked(db, response, daemon_id, &workspace_id).await?;
    }
    Ok(())
}

fn matching_workspace_conflict<'a>(
    response: &'a AgentWorkspaceListResponse,
    project_scope_id: &str,
    checkout_id: &str,
    legacy_session_ids: &[String],
) -> Option<&'a AgentWorkspaceConflict> {
    response.conflicts.iter().find(|conflict| {
        (conflict.project_scope_id == project_scope_id && conflict.checkout_id == checkout_id)
            || conflict
                .legacy_session_ids
                .iter()
                .any(|session_id| legacy_session_ids.contains(session_id))
    })
}

fn reconciliation_conflict_error(
    subject: &str,
    identity: &str,
    conflict: &AgentWorkspaceConflict,
) -> CliError {
    CliErrorKind::concurrent_modification(format!(
        "{subject} '{identity}' reconciliation is blocked: {}",
        conflict.detail
    ))
    .into()
}

const fn managed_kind_label(kind: ManagedAgentKind) -> &'static str {
    match kind {
        ManagedAgentKind::Tui => "tui",
        ManagedAgentKind::Acp => "acp",
        ManagedAgentKind::Codex => "codex",
    }
}

pub(super) async fn prepare_session_deletion_async(
    db: &AsyncDaemonDbHandle,
    session_id: &str,
) -> Result<(), CliError> {
    let identity = tokio::task::spawn_blocking(state::ensure_daemon_identity)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join daemon identity read: {error}"))
        })??;
    reconcile_session_deletion_source(db, &identity.daemon_id, session_id).await
}

pub(super) fn prepare_session_deletion(
    db: &DaemonDbOwnedHandle,
    session_id: &str,
) -> Result<(), CliError> {
    let Some(path) = db.0.path.clone() else {
        return Ok(());
    };
    let identity = state::ensure_daemon_identity()?;
    let session_id = session_id.to_string();
    let worker = std::thread::Builder::new()
        .name("harness-session-delete-reconcile".to_string())
        .spawn(move || reconcile_before_sync_deletion(&path, &identity.daemon_id, &session_id))
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn Session deletion reconciliation: {error}"))
        })?;
    worker
        .join()
        .map_err(|_| CliErrorKind::workflow_io("Session deletion reconciliation worker panicked"))?
}

pub(super) fn delete_session_with_durable_team(
    db: &DaemonDbOwnedHandle,
    session_id: &str,
) -> Result<bool, CliError> {
    prepare_session_deletion(db, session_id)?;
    let transaction =
        rusqlite::Transaction::new_unchecked(db.connection(), TransactionBehavior::Immediate)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("begin Session deletion: {error}"))
            })?;
    let state_json = transaction
        .query_row(
            "SELECT state_json FROM sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("load Session deletion state: {error}"))
        })?;
    let Some(state_json) = state_json else {
        return Ok(false);
    };
    let state: SessionState = serde_json::from_str(&state_json).map_err(|error| {
        CliErrorKind::workflow_io(format!("parse Session deletion state: {error}"))
    })?;
    transaction
        .execute("DELETE FROM sessions WHERE session_id = ?1", [session_id])
        .map_err(|error| CliErrorKind::workflow_io(format!("delete Session row: {error}")))?;
    harness_daemon_session_service::destroy_session_artifacts(&state)?;
    transaction
        .commit()
        .map_err(|error| CliErrorKind::workflow_io(format!("commit Session deletion: {error}")))?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(true)
}

pub(crate) async fn delete_session_with_artifact_cleanup_async<F>(
    db: &AsyncDaemonDbHandle,
    session_id: &str,
    cleanup: F,
) -> Result<bool, CliError>
where
    F: FnOnce(SessionState) -> Result<(), CliError> + Send + 'static,
{
    prepare_session_deletion_async(db, session_id).await?;
    let mut transaction = db
        .pool()
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("begin Session deletion: {error}")))?;
    let state_json =
        query_scalar::<_, String>("SELECT state_json FROM sessions WHERE session_id = ?1")
            .bind(session_id)
            .fetch_optional(transaction.as_mut())
            .await
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("load Session deletion state: {error}"))
            })?;
    let Some(state_json) = state_json else {
        transaction.rollback().await.map_err(|error| {
            CliErrorKind::workflow_io(format!("close empty Session deletion: {error}"))
        })?;
        return Ok(false);
    };
    let state: SessionState = serde_json::from_str(&state_json).map_err(|error| {
        CliErrorKind::workflow_io(format!("parse Session deletion state: {error}"))
    })?;
    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("delete Session row: {error}")))?;
    tokio::task::spawn_blocking(move || cleanup(state))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join Session artifact cleanup: {error}"))
        })??;
    transaction
        .commit()
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("commit Session deletion: {error}")))?;
    db.bump_change(session_id).await?;
    db.bump_change("global").await?;
    Ok(true)
}

fn reconcile_before_sync_deletion(
    path: &std::path::Path,
    daemon_id: &str,
    session_id: &str,
) -> Result<(), CliError> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("build Session deletion runtime: {error}"))
        })?;
    runtime.block_on(async {
        let db = AsyncDaemonDb::connect(path).await?;
        reconcile_session_deletion_source(&AsyncDaemonDbHandle(db), daemon_id, session_id).await
    })
}

async fn reconcile_session_deletion_source(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    session_id: &str,
) -> Result<(), CliError> {
    let workspaces = db.reconcile_agent_workspaces(daemon_id).await?;
    if workspaces.conflicts.iter().any(|conflict| {
        conflict
            .legacy_session_ids
            .iter()
            .any(|id| id == session_id)
    }) {
        return Err(CliErrorKind::workflow_io(format!(
            "cannot delete Session '{session_id}' while workspace reconciliation is blocked"
        ))
        .into());
    }
    let workspace_ids = query_scalar::<_, String>(
        "SELECT link.workspace_id FROM agent_workspace_legacy_sessions link
         JOIN agent_workspaces workspace ON workspace.workspace_id = link.workspace_id
         WHERE workspace.daemon_id = ?1 AND link.session_id = ?2
         ORDER BY link.workspace_id",
    )
    .bind(daemon_id)
    .bind(session_id)
    .fetch_all(db.pool())
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("load Session workspace provenance: {error}"))
    })?;
    for workspace_id in workspace_ids {
        let team = db
            .reconcile_agent_workspace_team(daemon_id, &workspace_id)
            .await?;
        if !team.conflicts.is_empty() {
            return Err(CliErrorKind::workflow_io(format!(
                "cannot delete Session '{session_id}' while its durable team is blocked"
            ))
            .into());
        }
        db.load_agent_workspace_activity(
            daemon_id,
            &workspace_id,
            &TimelineWindowRequest::default(),
        )
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod conflict_tests {
    use harness_protocol::daemon::summaries::AgentWorkspaceConflictKind;

    use super::*;

    #[test]
    fn workspace_conflict_matching_is_scoped_to_the_requested_checkout() {
        let response = AgentWorkspaceListResponse {
            workspaces: Vec::new(),
            conflicts: vec![AgentWorkspaceConflict {
                daemon_id: "daemon-test".to_string(),
                project_scope_id: "project-target".to_string(),
                checkout_id: "checkout-target".to_string(),
                kind: AgentWorkspaceConflictKind::ActiveOwnerCollision,
                legacy_session_ids: vec!["session-a".to_string(), "session-b".to_string()],
                detail: "two active owners".to_string(),
            }],
        };

        assert!(
            matching_workspace_conflict(&response, "project-target", "checkout-target", &[])
                .is_some()
        );
        assert!(
            matching_workspace_conflict(
                &response,
                "project-old",
                "checkout-target",
                &["session-a".to_string()]
            )
            .is_some()
        );
        assert!(
            matching_workspace_conflict(
                &response,
                "project-unrelated",
                "checkout-target",
                &["session-unrelated".to_string()]
            )
            .is_none()
        );
    }
}
