//! Host-local executor loop for durably claimed remote Task Board attempts.
//!
//! The controller owns workflow progression. This loop owns only the executor-side checkout and
//! deterministic Codex worker. It never accepts a controller-local session or worktree path.

use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorIdentity,
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteExecutorStartIoPermitOutcome, executor_start_authority,
    executor_start_io_permit, remote_executor_identity,
};
use crate::daemon::http::DaemonHttpState;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::workspace::utc_now;

#[path = "task_board_remote_executor_loop/adoption.rs"]
mod adoption;
#[path = "task_board_remote_executor_loop/cleanup.rs"]
mod cleanup;
#[path = "task_board_remote_executor_loop/fences.rs"]
mod fences;
#[path = "task_board_remote_executor_loop/runtime.rs"]
mod runtime;
#[path = "task_board_remote_executor_loop/scan.rs"]
mod scan;
#[path = "task_board_remote_executor_loop/source.rs"]
mod source;
#[path = "task_board_remote_executor_loop/source_bundle.rs"]
mod source_bundle;
#[path = "task_board_remote_executor_loop/stop.rs"]
mod stop;
#[path = "task_board_remote_executor_loop/terminal.rs"]
mod terminal;
use adoption::execute_and_reconcile_remote_worker;
use adoption::reconcile_persisted_start_without_run;
use cleanup::{cleanup_unstarted_executor_provisioning, reconcile_settled_executor_cleanup};
use fences::{concurrent, invalid_transition, require_executor_identity, shutdown_observed};
#[cfg(test)]
use runtime::remote_codex_request;
use runtime::{
    PreparedRemoteWorkerAction, RemoteWorkerAction, start_window_is_open, stop_codex_run,
    validate_run_identity, worker_action,
};
use scan::executor_assignment_ids;
use source::prepare_remote_workspace;
use stop::{reconcile_stop_pending, settle_lifecycle_settings_drift};

pub(super) type RemoteWorkerIdentity = TaskBoardRemoteExecutorIdentity;
pub(super) const REMOTE_START_EXPIRED_REASON: &str =
    "remote assignment expired before executor start";

#[cfg(test)]
pub(crate) use test_seam::{RuntimeSeamScope, install_deterministic_runtime_seam};

pub(super) fn spawn_task_board_remote_executor_loop(
    state: DaemonHttpState,
    poll_interval: Duration,
    mut shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            if *shutdown_rx.borrow() {
                break;
            }
            if let Err(error) =
                reconcile_remote_executor_assignments(&state, Some(&shutdown_rx)).await
            {
                tracing::warn!(%error, "remote Task Board executor scan failed");
            }
            tokio::select! {
                () = sleep(poll_interval) => {}
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() {
                        break;
                    }
                }
            }
        }
    })
}

async fn reconcile_remote_executor_assignments(
    state: &DaemonHttpState,
    shutdown_rx: Option<&watch::Receiver<bool>>,
) -> Result<(), CliError> {
    let db = state.async_db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "remote executor requires the async daemon database".to_string(),
        ))
    })?;
    let assignment_ids = executor_assignment_ids(db.as_ref()).await?;
    for assignment_id in assignment_ids {
        if let Err(error) = reconcile_remote_executor_assignment_with_shutdown(
            state,
            db.as_ref(),
            &assignment_id,
            shutdown_rx,
        )
        .await
        {
            tracing::warn!(%assignment_id, %error, "remote Task Board executor assignment deferred");
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) async fn reconcile_task_board_remote_executor_tick(
    state: &DaemonHttpState,
) -> Result<(), CliError> {
    reconcile_remote_executor_assignments(state, None).await
}

async fn reconcile_remote_executor_assignment(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    assignment_id: &str,
) -> Result<(), CliError> {
    reconcile_remote_executor_assignment_with_shutdown(state, db, assignment_id, None).await
}

async fn reconcile_remote_executor_assignment_with_shutdown(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    assignment_id: &str,
    shutdown_rx: Option<&watch::Receiver<bool>>,
) -> Result<(), CliError> {
    let Some(initial) = db.task_board_remote_assignment(assignment_id).await? else {
        return Ok(());
    };
    let identity = remote_executor_identity(&initial)?;
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&identity.session_id, &identity.run_id)
        .await;
    let Some(record) = db.task_board_remote_assignment(assignment_id).await? else {
        return Ok(());
    };
    if let Some(pending) = record.executor_stop_pending.as_ref() {
        return reconcile_stop_pending(state, db, pending).await;
    }
    if matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Completed
            | TaskBoardRemoteAssignmentState::Failed
            | TaskBoardRemoteAssignmentState::Cancelled
            | TaskBoardRemoteAssignmentState::Unknown
            | TaskBoardRemoteAssignmentState::Superseded
    ) && reconcile_settled_executor_cleanup(state, db, &record, &identity).await?
    {
        return Ok(());
    }
    if matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Cancelled | TaskBoardRemoteAssignmentState::Unknown
    ) {
        return stop_terminal_remote_worker(state, db, &record, &identity).await;
    }
    reconcile_active_remote_worker(state, db, record, &identity, shutdown_rx).await
}

async fn reconcile_active_remote_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    mut record: TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    shutdown_rx: Option<&watch::Receiver<bool>>,
) -> Result<(), CliError> {
    require_executor_identity(&record)?;
    let offer = record.require_offer()?.clone();
    if offer.launch.runtime != "codex" {
        return Err(invalid_transition(
            "remote executor supports only the Codex runtime",
        ));
    }
    let existing = db.codex_run(&identity.run_id).await?;
    let action = worker_action(record.state, existing.as_ref().map(|run| run.status));
    if action == RemoteWorkerAction::Hold {
        return Ok(());
    }
    let Some(owned) = claim_active_lifecycle_owner(state, db, &record).await? else {
        return Ok(());
    };
    record = owned.record;
    if owned.stop_only {
        let snapshot = existing
            .as_ref()
            .ok_or_else(|| concurrent("launch-drifted remote executor has no durable run"))?;
        return settle_lifecycle_settings_drift(state, db, &record, snapshot).await;
    }
    let Some(prepared) = prepare_active_remote_worker(
        db,
        &record,
        &offer,
        identity,
        action,
        &state.daemon_epoch,
        shutdown_rx,
    )
    .await?
    else {
        return Ok(());
    };
    execute_and_reconcile_remote_worker(
        state,
        db,
        record,
        &offer,
        identity,
        prepared.action,
        &prepared.workspace,
    )
    .await
}

struct PreparedRemoteWorker {
    workspace: std::path::PathBuf,
    action: PreparedRemoteWorkerAction,
}

async fn prepare_active_remote_worker(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: RemoteWorkerAction,
    daemon_epoch: &str,
    shutdown_rx: Option<&watch::Receiver<bool>>,
) -> Result<Option<PreparedRemoteWorker>, CliError> {
    let persisted_permit = executor_start_io_permit(record)?;
    // Durable permit or run evidence has passed the fresh-start boundary;
    // recover from it without provisioning or another Start.
    if persisted_permit.is_some() || action == RemoteWorkerAction::Probe {
        return prepare_recovery(db, record, identity, action, persisted_permit).await;
    }
    // Only this no-permit, no-run path may provision and Start.
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    let persisted_authority = executor_start_authority(record)?;
    // The wall-clock window gates only a fresh claim; authorized generations
    // still reconcile after it closes so expired provisioning cannot leak.
    if persisted_authority.is_none()
        && !start_window_is_open(
            record.lease_expires_at.as_deref().unwrap_or_default(),
            record.deadline_at.as_deref().unwrap_or_default(),
            &utc_now(),
        )?
    {
        return Ok(None);
    }
    let Some(authority) = start_authority_for_action(
        db,
        record,
        identity,
        action,
        persisted_authority,
        daemon_epoch,
    )
    .await?
    else {
        return Ok(None);
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    if record.claimed_host_instance_id.as_deref() != Some(daemon_epoch) {
        cleanup_predecessor_remote_start(db, Some(&authority), daemon_epoch).await?;
        return Ok(None);
    }
    let Some(authority) = authorize_or_cleanup_remote_provisioning(db, Some(&authority)).await?
    else {
        return Ok(None);
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    let workspace = match prepare_remote_workspace(db, record, offer, identity, true).await {
        Ok(workspace) => workspace,
        Err(error) => {
            if authorize_or_cleanup_remote_provisioning(db, Some(&authority))
                .await?
                .is_none()
            {
                return Ok(None);
            }
            return Err(error);
        }
    };
    if shutdown_observed(shutdown_rx) {
        return Ok(None);
    }
    match claim_or_cleanup_remote_start_io(db, Some(&authority), &workspace).await? {
        TaskBoardRemoteExecutorStartIoPermitOutcome::Acquired(permit) => {
            Ok(Some(PreparedRemoteWorker {
                workspace,
                action: PreparedRemoteWorkerAction::Start(permit),
            }))
        }
        // A fresh-path replay or stale outcome never starts.
        TaskBoardRemoteExecutorStartIoPermitOutcome::Replayed(_)
        | TaskBoardRemoteExecutorStartIoPermitOutcome::Stale => Ok(None),
    }
}

/// Recovery from a durable permit or run never provisions or launches Start.
async fn prepare_recovery(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    action: RemoteWorkerAction,
    persisted_permit: Option<TaskBoardRemoteExecutorStartIoPermit>,
) -> Result<Option<PreparedRemoteWorker>, CliError> {
    if action != RemoteWorkerAction::Probe {
        let permit = persisted_permit.as_ref().ok_or_else(|| {
            concurrent("remote executor recovery has neither a run nor a Start I/O permit")
        })?;
        // Transactional failure settlement rechecks the run under its fence.
        reconcile_persisted_start_without_run(db, record, permit).await?;
        return Ok(None);
    }
    // Resolve only the existing session; a pre-permit run follows this Probe path.
    let Some(session) = db.resolve_session(&identity.session_id).await? else {
        return Ok(None);
    };
    Ok(Some(PreparedRemoteWorker {
        workspace: session.state.worktree_path,
        action: PreparedRemoteWorkerAction::Probe(persisted_permit),
    }))
}

async fn authorize_or_cleanup_remote_provisioning(
    db: &AsyncDaemonDb,
    authority: Option<&TaskBoardRemoteExecutorStartAuthority>,
) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
    let authority = authority
        .ok_or_else(|| concurrent("claimed remote worker has no durable start authority"))?;
    if let Some(authorized) = db
        .authorize_task_board_remote_executor_provisioning(authority, &utc_now())
        .await?
    {
        return Ok(Some(authorized));
    }
    if !cleanup_unstarted_executor_provisioning(db, authority).await? {
        return Ok(None);
    }
    let _ = db
        .revoke_task_board_remote_executor_start_after_cleanup(authority, &utc_now())
        .await?;
    Ok(None)
}

async fn claim_or_cleanup_remote_start_io(
    db: &AsyncDaemonDb,
    authority: Option<&TaskBoardRemoteExecutorStartAuthority>,
    workspace: &std::path::Path,
) -> Result<TaskBoardRemoteExecutorStartIoPermitOutcome, CliError> {
    let authority = authority
        .ok_or_else(|| concurrent("claimed remote worker has no provisioning authority"))?;
    let outcome = db
        .claim_task_board_remote_executor_start_io_permit(authority, workspace, &utc_now())
        .await?;
    if matches!(outcome, TaskBoardRemoteExecutorStartIoPermitOutcome::Stale)
        && cleanup_unstarted_executor_provisioning(db, authority).await?
    {
        let _ = db
            .revoke_task_board_remote_executor_start_after_cleanup(authority, &utc_now())
            .await?;
    }
    Ok(outcome)
}

async fn cleanup_predecessor_remote_start(
    db: &AsyncDaemonDb,
    authority: Option<&TaskBoardRemoteExecutorStartAuthority>,
    successor_instance_id: &str,
) -> Result<(), CliError> {
    let authority = authority
        .ok_or_else(|| concurrent("predecessor remote worker has no durable start authority"))?;
    if !cleanup_unstarted_executor_provisioning(db, authority).await? {
        return Ok(());
    }
    let _ = db
        .abandon_task_board_remote_executor_start_after_restart(
            authority,
            successor_instance_id,
            &utc_now(),
        )
        .await?;
    Ok(())
}

struct ActiveLifecycleOwner {
    record: TaskBoardRemoteAssignmentRecord,
    stop_only: bool,
}

async fn claim_active_lifecycle_owner(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<Option<ActiveLifecycleOwner>, CliError> {
    if !matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
    ) {
        return Ok(Some(ActiveLifecycleOwner {
            record: record.clone(),
            stop_only: false,
        }));
    }
    let Some(claim) = db
        .claim_task_board_remote_executor_lifecycle_owner_with_settings(
            &record.assignment_id,
            &state.daemon_epoch,
            &utc_now(),
        )
        .await?
    else {
        return Ok(None);
    };
    let record = db
        .task_board_remote_assignment(&record.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote executor assignment disappeared after ownership"))?;
    Ok(Some(ActiveLifecycleOwner {
        record,
        stop_only: claim.stop_only,
    }))
}

async fn start_authority_for_action(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    action: RemoteWorkerAction,
    persisted: Option<TaskBoardRemoteExecutorStartAuthority>,
    current_instance_id: &str,
) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
    if record.state != TaskBoardRemoteAssignmentState::Claimed {
        return Ok(None);
    }
    if action == RemoteWorkerAction::Probe {
        return persisted
            .map(Some)
            .ok_or_else(|| concurrent("durable remote run has no start authority"));
    }
    if let Some(authority) = persisted {
        return Ok(Some(authority));
    }
    let authority = db
        .claim_task_board_remote_executor_start_authority(
            &record.assignment_id,
            current_instance_id,
            &utc_now(),
        )
        .await?;
    if authority
        .as_ref()
        .is_some_and(|authority| authority.identity != *identity)
    {
        return Err(concurrent("remote executor start identity mismatched"));
    }
    Ok(authority)
}

async fn stop_terminal_remote_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let Some(snapshot) = db.codex_run(&identity.run_id).await? else {
        return Ok(());
    };
    require_executor_identity(record)?;
    let offer = record.require_offer()?;
    validate_run_identity(&snapshot, offer, identity)?;
    if !snapshot.status.is_active() {
        return Ok(());
    }
    let run_id = identity.run_id.clone();
    stop_codex_run(state, &run_id).await
}

#[cfg(test)]
#[path = "task_board_remote_executor_loop/disabled_tests.rs"]
mod disabled_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/restart_cleanup_tests.rs"]
mod restart_cleanup_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/runtime_seam_tests.rs"]
mod runtime_seam_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/settings_lifecycle_tests.rs"]
mod settings_lifecycle_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/start_io_permit_tests.rs"]
mod start_io_permit_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/start_permit_state_machine_tests.rs"]
mod start_permit_state_machine_tests;
#[cfg(test)]
#[path = "task_board_remote_executor_loop/test_seam.rs"]
mod test_seam;
#[cfg(test)]
#[path = "task_board_remote_executor_loop_tests.rs"]
mod tests;
