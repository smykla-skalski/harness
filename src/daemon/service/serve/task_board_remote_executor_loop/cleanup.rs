use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use super::RemoteWorkerIdentity;
use super::runtime::{stop_codex_run, validate_run_snapshot};
use super::source_bundle::cleanup_prior_phase_import_ref;
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStopReason, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::http::DaemonHttpState;
use crate::errors::{CliError, CliErrorKind};
use crate::session::storage as session_storage;
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;
use crate::workspace::worktree::WorktreeController;

pub(super) async fn reconcile_settled_executor_cleanup(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<bool, CliError> {
    if record.cleanup_completed_at.is_some() {
        return Ok(true);
    }
    let Some(receipt) = db
        .task_board_remote_settlement_receipt(&record.assignment_id)
        .await?
    else {
        return Ok(false);
    };
    require_exact_cleanup_generation(record, &receipt.request)?;
    if preclaim_superseded_cleanup_is_empty(db, record, identity).await? {
        // A never-claimed offer performed no executor work and owns no local filesystem state.
    } else {
        if let Some(run) = db.codex_run(&identity.run_id).await? {
            validate_cleanup_run(db, record, identity, &run).await?;
            if run.status.is_active() {
                stop_codex_run(state, &identity.run_id).await?;
                return Ok(true);
            }
        }
        let workspace = db
            .resolve_session(&identity.session_id)
            .await?
            .map(|session| session.state.worktree_path);
        cleanup_prior_phase_import_ref(record, identity, workspace.as_deref()).await?;
        cleanup_executor_session(db, record, identity).await?;
    }
    match db
        .complete_task_board_remote_assignment_cleanup(
            &receipt.request,
            &receipt.authenticated_principal,
            &utc_now(),
        )
        .await?
    {
        TaskBoardRemoteMutationOutcome::Updated(_)
        | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(true),
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
            "remote executor cleanup lost its exact settlement fence",
        )),
    }
}

pub(super) async fn cleanup_unstarted_executor_provisioning(
    db: &AsyncDaemonDb,
    authority: &TaskBoardRemoteExecutorStartAuthority,
) -> Result<bool, CliError> {
    let Some(record) = db
        .task_board_remote_assignment(&authority.assignment_id)
        .await?
    else {
        return Ok(false);
    };
    if !exact_unstarted_provisioning(&record, authority) {
        return Ok(false);
    }
    if db.codex_run(&authority.identity.run_id).await?.is_some() {
        return Err(concurrent(
            "remote executor provisioning cleanup found a durable run",
        ));
    }
    let origin = PathBuf::from(record.executor_checkout_path.as_deref().ok_or_else(|| {
        concurrent("remote executor provisioning cleanup has no frozen checkout path")
    })?);
    let resolved = db.resolve_session(&authority.identity.session_id).await?;
    let layout =
        match resolved.as_ref() {
            Some(session) => cleanup_layout(
                session.state.worktree_path.to_str().ok_or_else(|| {
                    concurrent("remote executor provisioning worktree is not UTF-8")
                })?,
                &authority.identity.session_id,
            )?,
            None => deterministic_session_layout(&origin, &authority.identity.session_id)?,
        };
    if let Some(session) = resolved.as_ref() {
        validate_provisioning_session(&record, authority, &session.state, &layout)?;
    }
    let workspace = layout.workspace();
    cleanup_prior_phase_import_ref(
        &record,
        &authority.identity,
        workspace.exists().then_some(workspace.as_path()),
    )
    .await?;
    let cleanup_origin = origin.clone();
    spawn_blocking(move || destroy_executor_session(cleanup_origin, layout))
        .await
        .map_err(|error| workflow_io(format!("join remote provisioning cleanup: {error}")))??;
    if resolved.is_some() {
        db.delete_session_row(&authority.identity.session_id)
            .await?;
    }
    Ok(true)
}

fn exact_unstarted_provisioning(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
) -> bool {
    record.state == crate::task_board::TaskBoardRemoteAssignmentState::Claimed
        && record.fencing_epoch == authority.fencing_epoch
        && record.executor_start_authority_sha256.as_deref() == Some(authority.sha256.as_str())
        && record.executor_start_authority_at.as_deref() == Some(authority.acquired_at.as_str())
        && record.start_receipt.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
}

async fn preclaim_superseded_cleanup_is_empty(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<bool, CliError> {
    if record.state != crate::task_board::TaskBoardRemoteAssignmentState::Superseded {
        return Ok(false);
    }
    let exact = record.claimed_at.is_none()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.claim_receipt.is_none()
        && record.start_receipt.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
        && record.status_response.is_none()
        && record.status_sha256.is_none()
        && record.result_sha256.is_none();
    if !exact {
        return Err(concurrent(
            "preclaim superseded cleanup contains executor work evidence",
        ));
    }
    if db.codex_run(&identity.run_id).await?.is_some()
        || db.resolve_session(&identity.session_id).await?.is_some()
    {
        return Err(concurrent(
            "preclaim superseded cleanup found unexpected executor state",
        ));
    }
    Ok(true)
}

fn require_exact_cleanup_generation(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &crate::daemon::task_board_remote_transport::wire::RemoteSettledRequest,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    if request.binding != offer.binding
        || request.offer_request_sha256 != offer.request_sha256
        || request.lease_id != record.lease_id.as_deref().unwrap_or_default()
    {
        return Err(concurrent(
            "remote executor cleanup receipt belongs to another assignment generation",
        ));
    }
    Ok(())
}

async fn cleanup_executor_session(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let Some(resolved) = db.resolve_session(&identity.session_id).await? else {
        return cleanup_orphan_executor_session(db, record, identity).await;
    };
    let project_dir = record
        .start_receipt
        .as_ref()
        .map(|start| start.project_dir.as_str())
        .unwrap_or_else(|| resolved.state.worktree_path.to_str().unwrap_or_default());
    let layout = cleanup_layout(project_dir, &identity.session_id)?;
    validate_cleanup_session(record, identity, &resolved.state, &layout)?;
    let origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    );
    let layout_for_worker = layout.clone();
    spawn_blocking(move || destroy_executor_session(origin, layout_for_worker))
        .await
        .map_err(|error| workflow_io(format!("join remote executor cleanup: {error}")))??;
    db.delete_session_row(&identity.session_id).await?;
    Ok(())
}

async fn validate_cleanup_run(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    run: &crate::daemon::protocol::CodexRunSnapshot,
) -> Result<(), CliError> {
    if let Some(start) = record.start_receipt.as_ref() {
        return validate_run_snapshot(
            run,
            record.require_offer()?,
            identity,
            Path::new(&start.project_dir),
        );
    }
    require_unadopted_stop_cleanup(record)?;
    if run.run_id != identity.run_id || run.session_id != identity.session_id {
        return Err(concurrent(
            "unadopted remote cleanup run identity mismatched",
        ));
    }
    let session = db
        .resolve_session(&identity.session_id)
        .await?
        .ok_or_else(|| concurrent("unadopted remote cleanup run has no durable session"))?;
    if session.state.worktree_path != PathBuf::from(&run.project_dir) {
        return Err(concurrent(
            "unadopted remote cleanup run uses another session worktree",
        ));
    }
    let layout = cleanup_layout(&run.project_dir, &identity.session_id)?;
    validate_cleanup_session(record, identity, &session.state, &layout)
}

fn validate_cleanup_session(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    state: &crate::session::types::SessionState,
    layout: &SessionLayout,
) -> Result<(), CliError> {
    if record.start_receipt.is_none() {
        require_unadopted_stop_cleanup(record)?;
    }
    validate_executor_session_identity(record, identity, state, layout)
}

fn validate_provisioning_session(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    state: &crate::session::types::SessionState,
    layout: &SessionLayout,
) -> Result<(), CliError> {
    if !exact_unstarted_provisioning(record, authority) {
        return Err(concurrent(
            "remote executor provisioning session lost its exact start authority",
        ));
    }
    validate_executor_session_identity(record, &authority.identity, state, layout)
}

fn validate_executor_session_identity(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    state: &crate::session::types::SessionState,
    layout: &SessionLayout,
) -> Result<(), CliError> {
    let expected_origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    );
    let exact = state.session_id == identity.session_id
        && state.project_name == layout.project_name
        && state.worktree_path == layout.workspace()
        && state.shared_path == layout.memory()
        && state.origin_path == expected_origin
        && state.branch_ref == layout.branch_ref()
        && state.title == format!("Remote Task Board {}", record.execution_id)
        && state.context
            == format!(
                "Remote Task Board assignment {} fencing epoch {}",
                record.assignment_id, record.fencing_epoch
            );
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote executor cleanup session identity mismatched",
        ))
    }
}

fn require_unadopted_stop_cleanup(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let stop_reason = [
        TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
        TaskBoardRemoteExecutorStopReason::StartAdoptionFenceLost,
        TaskBoardRemoteExecutorStopReason::StartAdoptionFailed,
        TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
    ]
    .into_iter()
    .any(|reason| record.error.as_deref() == Some(reason.message()));
    let start_expired = record.error.as_deref() == Some(super::REMOTE_START_EXPIRED_REASON);
    let settings_changed =
        record.error.as_deref() == Some("remote executor settings changed before worker start");
    let executor_restarted =
        record.error.as_deref() == Some("remote executor restarted before worker start");
    // Both terminals share the no-run "claimed, never started, cleanly finalized"
    // shape. Failed-at-Claimed must additionally carry the decoded receipt, not merely
    // resemble it, because a raw Failed row has no proof that external Start never ran.
    let unadopted_shape = record.claim_receipt.is_some()
        && record.started_at.is_none()
        && record.workspace_ref.is_none()
        && record.start_receipt.is_none()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none();
    let stopped_unknown = record.state
        == crate::task_board::TaskBoardRemoteAssignmentState::Unknown
        && (stop_reason || start_expired || settings_changed || executor_restarted);
    let failed_at_claimed = record.state
        == crate::task_board::TaskBoardRemoteAssignmentState::Failed
        && record.start_failure_receipt.is_some();
    if unadopted_shape && (stopped_unknown || failed_at_claimed) {
        Ok(())
    } else {
        Err(concurrent(
            "unadopted remote cleanup lacks exact stopped-run evidence",
        ))
    }
}

async fn cleanup_orphan_executor_session(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    if db.codex_run(&identity.run_id).await?.is_some() {
        return Err(concurrent(
            "unstarted remote cleanup found an unowned deterministic session",
        ));
    }
    let origin =
        PathBuf::from(record.executor_checkout_path.as_deref().ok_or_else(|| {
            concurrent("remote executor orphan cleanup has no frozen checkout path")
        })?);
    let layout = if let Some(start) = record.start_receipt.as_ref() {
        cleanup_layout(&start.project_dir, &identity.session_id)?
    } else {
        require_unadopted_stop_cleanup(record)?;
        deterministic_session_layout(&origin, &identity.session_id)?
    };
    if !layout.session_root().exists() {
        return Ok(());
    }
    spawn_blocking(move || destroy_executor_session(origin, layout))
        .await
        .map_err(|error| workflow_io(format!("join remote orphan cleanup: {error}")))?
}

fn deterministic_session_layout(
    origin: &Path,
    session_id: &str,
) -> Result<SessionLayout, CliError> {
    let canonical_origin = origin
        .canonicalize()
        .map_err(|error| workflow_io(format!("canonicalize remote cleanup origin: {error}")))?;
    let sessions_root =
        crate::workspace::layout::sessions_root(&crate::workspace::harness_data_root());
    let project_name =
        crate::workspace::project_resolver::resolve_name(&canonical_origin, &sessions_root)
            .map_err(|error| workflow_io(format!("resolve remote cleanup project: {error}")))?;
    Ok(SessionLayout {
        sessions_root,
        project_name,
        session_id: session_id.into(),
    })
}

fn cleanup_layout(project_dir: &str, session_id: &str) -> Result<SessionLayout, CliError> {
    let workspace = Path::new(project_dir);
    let session_root = workspace
        .parent()
        .filter(|_| {
            workspace
                .file_name()
                .is_some_and(|name| name == "workspace")
        })
        .ok_or_else(|| concurrent("remote executor cleanup worktree path is not canonical"))?;
    if session_root.file_name().and_then(|name| name.to_str()) != Some(session_id) {
        return Err(concurrent(
            "remote executor cleanup worktree does not match its session",
        ));
    }
    let project = session_root
        .parent()
        .ok_or_else(|| concurrent("remote executor cleanup session has no project directory"))?;
    let sessions_root = project
        .parent()
        .ok_or_else(|| concurrent("remote executor cleanup session has no sessions root"))?;
    let project_name = project
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| concurrent("remote executor cleanup project name is invalid"))?;
    let layout = SessionLayout {
        sessions_root: sessions_root.into(),
        project_name: project_name.into(),
        session_id: session_id.into(),
    };
    if layout.workspace() != workspace {
        return Err(concurrent(
            "remote executor cleanup worktree path is not normalized",
        ));
    }
    Ok(layout)
}

fn destroy_executor_session(origin: PathBuf, layout: SessionLayout) -> Result<(), CliError> {
    if !layout.session_root().exists() {
        return Ok(());
    }
    session_storage::deregister_active(&layout)?;
    WorktreeController::destroy(&origin, &layout)
        .map_err(|error| workflow_io(format!("destroy remote executor worktree: {error}")))?;
    if layout.session_root().exists() {
        fs_err::remove_dir_all(layout.session_root())
            .map_err(|error| workflow_io(format!("remove remote executor session: {error}")))?;
    }
    Ok(())
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

fn workflow_io(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}

#[cfg(test)]
#[path = "cleanup_failure_tests.rs"]
mod failure_tests;
#[cfg(test)]
#[path = "cleanup_tests.rs"]
mod tests;
#[cfg(test)]
#[path = "cleanup_unadopted_tests.rs"]
mod unadopted_tests;
