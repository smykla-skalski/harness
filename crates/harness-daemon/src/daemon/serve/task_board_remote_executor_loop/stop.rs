//! Durable stop-only reconciliation for invalid or unadoptable executor runs.

use std::future::Future;
use std::pin::Pin;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorRun,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopPending,
    TaskBoardRemoteExecutorStopReason, TaskBoardRemoteMutationOutcome,
    stop_pending_snapshot_matches,
};
use crate::daemon::http::DaemonHttpState;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::runtime::stop_remote_run;
use crate::daemon::db::task_board::prelude::*;

pub(super) async fn settle_lifecycle_settings_drift(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &TaskBoardRemoteExecutorRun,
) -> Result<(), CliError> {
    let owner = record
        .executor_lifecycle_owner
        .as_ref()
        .ok_or_else(|| concurrent("launch-drifted remote executor has no lifecycle owner"))?;
    claim_and_settle_invalid_remote_run(
        state,
        db,
        &TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner.clone()),
        snapshot,
        TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
    )
    .await
}

pub(super) fn claim_and_settle_invalid_remote_run<'a>(
    state: &'a DaemonHttpState,
    db: &'a AsyncDaemonDb,
    authority: &'a TaskBoardRemoteExecutorStopAuthority,
    snapshot: &'a TaskBoardRemoteExecutorRun,
    reason: TaskBoardRemoteExecutorStopReason,
) -> Pin<Box<dyn Future<Output = Result<(), CliError>> + Send + 'a>> {
    Box::pin(async move {
        let pending = db
            .claim_task_board_remote_executor_stop_pending(authority, snapshot, reason, &utc_now())
            .await?
            .ok_or_else(|| concurrent("remote executor stop authority lost its source fence"))?;
        reconcile_stop_pending(state, db, &pending).await
    })
}

pub(super) fn reconcile_stop_pending<'a>(
    state: &'a DaemonHttpState,
    db: &'a AsyncDaemonDb,
    pending: &'a TaskBoardRemoteExecutorStopPending,
) -> Pin<Box<dyn Future<Output = Result<(), CliError>> + Send + 'a>> {
    Box::pin(async move {
        let record = db
            .task_board_remote_assignment(&pending.assignment_id)
            .await?
            .ok_or_else(|| concurrent("stop-pending remote executor assignment disappeared"))?;
        let offer = record.require_offer()?;
        let snapshot = db
            .task_board_remote_executor_run(offer, &pending.run_id)
            .await?
            .ok_or_else(|| concurrent("stop-pending remote executor run disappeared"))?;
        if !stop_pending_snapshot_matches(pending, &snapshot) {
            return Err(concurrent(
                "stop-pending remote executor run identity changed",
            ));
        }
        if snapshot.status.is_active() {
            stop_remote_run(state, db, &snapshot).await?;
        }
        let outcome = db
            .settle_task_board_remote_executor_stop_pending(pending, &utc_now())
            .await?;
        match outcome {
            TaskBoardRemoteMutationOutcome::Updated(_)
            | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(()),
            TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
                "remote executor stop remains ambiguous after cancellation",
            )),
        }
    })
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message.to_string()).into()
}
