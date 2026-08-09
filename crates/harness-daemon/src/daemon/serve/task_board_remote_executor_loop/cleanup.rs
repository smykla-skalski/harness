use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use super::RemoteWorkerIdentity;
use super::runtime::{stop_remote_run, validate_run_snapshot};
use super::source_bundle::cleanup_prior_phase_import_ref;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorRun,
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteMutationOutcome,
};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::http::DaemonHttpState;
use crate::session::storage as session_storage;
use crate::session::types::SessionState;
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::workspace::layout::SessionLayout;
use crate::workspace::utc_now;
use crate::workspace::worktree::WorktreeController;
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;
use harness_kernel::errors::{CliError, CliErrorKind};

#[path = "cleanup/fences.rs"]
mod fences;
#[path = "cleanup/layout.rs"]
mod layout;
#[path = "cleanup/workspace.rs"]
mod workspace;
use fences::{
    exact_unstarted_provisioning, preclaim_superseded_cleanup_is_empty,
    require_exact_cleanup_generation,
};
use layout::{cleanup_layout, deterministic_session_layout};
use workspace::{
    cleanup_executor_workspace, cleanup_unstarted_executor_workspace, validate_cleanup_workspace,
};

pub(super) async fn reconcile_settled_executor_cleanup(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
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
    // A never-claimed offer performed no executor work and owns no local filesystem state.
    if !preclaim_superseded_cleanup_is_empty(db, record, identity).await?
        && release_executor_local_state(state, db, record, identity).await?
    {
        // An active run was only just asked to stop, so the cleanup fence stays
        // open for the pass that observes it settled.
        return Ok(true);
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

/// Releases the local state an executor built for a settled assignment.
/// `Ok(true)` means an active runtime run was asked to stop and nothing else was
/// released yet, so the caller must leave the cleanup fence open this pass.
#[expect(
    clippy::cognitive_complexity,
    reason = "one guarded run-stop check ahead of the sequential local-state release"
)]
async fn release_executor_local_state(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    if let Some(run) = db
        .task_board_remote_executor_run(offer, &identity.run_id)
        .await?
    {
        validate_cleanup_run(db, record, identity, &run).await?;
        if run.status.is_active() {
            stop_remote_run(state, db, &run).await?;
            return Ok(true);
        }
    }
    let workspace = if offer.work_owner.is_some() {
        db.load_agent_working_copy(&identity.working_copy_id)
            .await?
            .map(|copy| PathBuf::from(copy.worktree_path))
    } else {
        db.resolve_session(&identity.session_id)
            .await?
            .map(|session| session.state.worktree_path)
    };
    cleanup_prior_phase_import_ref(record, identity, workspace.as_deref()).await?;
    if offer.work_owner.is_some() {
        cleanup_executor_workspace(db, record, identity).await?;
    } else {
        cleanup_executor_session(db, record, identity).await?;
    }
    Ok(false)
}

pub(super) async fn cleanup_unstarted_executor_provisioning(
    db: &AsyncDaemonDbHandle,
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
    let offer = record.require_offer()?;
    if db
        .task_board_remote_executor_run(offer, &authority.identity.run_id)
        .await?
        .is_some()
    {
        return Err(concurrent(
            "remote executor provisioning cleanup found a durable run",
        ));
    }
    let origin = PathBuf::from(record.executor_checkout_path.as_deref().ok_or_else(|| {
        concurrent("remote executor provisioning cleanup has no frozen checkout path")
    })?);
    if offer.work_owner.is_some() {
        let workspace = db
            .load_agent_working_copy(&authority.identity.working_copy_id)
            .await?
            .map(|copy| PathBuf::from(copy.worktree_path));
        cleanup_prior_phase_import_ref(&record, &authority.identity, workspace.as_deref()).await?;
        cleanup_unstarted_executor_workspace(db, &record, &authority.identity).await?;
        return Ok(true);
    }
    let (layout, had_session_row) =
        resolve_provisioning_layout(db, &record, authority, &origin).await?;
    let workspace = layout.workspace();
    cleanup_prior_phase_import_ref(
        &record,
        &authority.identity,
        workspace.exists().then_some(workspace.as_path()),
    )
    .await?;
    if had_session_row {
        crate::daemon::service::delete_session_with_artifact_cleanup_async(
            db,
            &authority.identity.session_id,
            move |_| destroy_executor_session(&origin, &layout),
        )
        .await?;
    } else {
        spawn_blocking(move || destroy_executor_session(&origin, &layout))
            .await
            .map_err(|error| workflow_io(format!("join remote provisioning cleanup: {error}")))??;
    }
    Ok(true)
}

/// Resolves the session layout whose filesystem state must be destroyed. The
/// flag reports whether a session row backed that layout, which is what decides
/// if the row itself has to be deleted once the files are gone.
async fn resolve_provisioning_layout(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    origin: &Path,
) -> Result<(SessionLayout, bool), CliError> {
    let Some(session) = db.resolve_session(&authority.identity.session_id).await? else {
        let layout = deterministic_session_layout(origin, &authority.identity.session_id)?;
        return Ok((layout, false));
    };
    let layout = cleanup_layout(
        session
            .state
            .worktree_path
            .to_str()
            .ok_or_else(|| concurrent("remote executor provisioning worktree is not UTF-8"))?,
        &authority.identity.session_id,
    )?;
    validate_provisioning_session(record, authority, &session.state, &layout)?;
    Ok((layout, true))
}

async fn cleanup_executor_session(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let Some(resolved) = db.resolve_session(&identity.session_id).await? else {
        return cleanup_orphan_executor_session(db, record, identity).await;
    };
    let project_dir = record.start_receipt.as_ref().map_or_else(
        || resolved.state.worktree_path.to_str().unwrap_or_default(),
        |start| start.project_dir.as_str(),
    );
    let layout = cleanup_layout(project_dir, &identity.session_id)?;
    validate_cleanup_session(record, identity, &resolved.state, &layout)?;
    let origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    );
    crate::daemon::service::delete_session_with_artifact_cleanup_async(
        db,
        &identity.session_id,
        move |_| destroy_executor_session(&origin, &layout),
    )
    .await?;
    Ok(())
}

pub(super) async fn validate_cleanup_run(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    run: &TaskBoardRemoteExecutorRun,
) -> Result<(), CliError> {
    if let Some(start) = record.start_receipt.as_ref() {
        if let Some(workspace_id) = start.workspace_id.clone() {
            return validate_run_snapshot(
                run,
                record.require_offer()?,
                identity,
                &super::PreparedRemoteWorkspace::owned(
                    PathBuf::from(&start.project_dir),
                    workspace_id,
                ),
            );
        }
        return validate_run_snapshot(
            run,
            record.require_offer()?,
            identity,
            &super::PreparedRemoteWorkspace::legacy(PathBuf::from(&start.project_dir)),
        );
    }
    require_unadopted_stop_cleanup(record)?;
    if run.run_id != identity.run_id {
        return Err(concurrent(
            "unadopted remote cleanup run identity mismatched",
        ));
    }
    if record.require_offer()?.work_owner.is_some() {
        let copy = db
            .load_agent_working_copy(&identity.working_copy_id)
            .await?
            .ok_or_else(|| concurrent("unadopted remote cleanup run has no working copy"))?;
        if run.session_id != copy.workspace_id || run.project_dir != copy.worktree_path {
            return Err(concurrent(
                "unadopted remote cleanup run uses another workspace",
            ));
        }
        return validate_cleanup_workspace(record, identity, &copy);
    }
    if run.session_id != identity.session_id {
        return Err(concurrent(
            "unadopted remote cleanup run identity mismatched",
        ));
    }
    let session = db
        .resolve_session(&identity.session_id)
        .await?
        .ok_or_else(|| concurrent("unadopted remote cleanup run has no durable session"))?;
    if session.state.worktree_path.as_path() != Path::new(&run.project_dir) {
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
    state: &SessionState,
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
    state: &SessionState,
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
    state: &SessionState,
    layout: &SessionLayout,
) -> Result<(), CliError> {
    let expected_origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    )
    .canonicalize()
    .map_err(|error| workflow_io(format!("canonicalize remote cleanup origin: {error}")))?;
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
    let stopped_unknown = record.state == TaskBoardRemoteAssignmentState::Unknown
        && (stop_reason || start_expired || settings_changed || executor_restarted);
    let failed_at_claimed = record.state == TaskBoardRemoteAssignmentState::Failed
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
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    if db
        .task_board_remote_executor_run(offer, &identity.run_id)
        .await?
        .is_some()
    {
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
    spawn_blocking(move || destroy_executor_session(&origin, &layout))
        .await
        .map_err(|error| workflow_io(format!("join remote orphan cleanup: {error}")))?
}

fn destroy_executor_session(origin: &Path, layout: &SessionLayout) -> Result<(), CliError> {
    if !layout.session_root().exists() {
        return Ok(());
    }
    session_storage::deregister_active(layout)?;
    WorktreeController::destroy(origin, layout)
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
