//! Durable stop-only reconciliation for invalid or unadoptable executor runs.

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStopAuthority,
    TaskBoardRemoteExecutorStopPending, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteMutationOutcome, stop_pending_snapshot_matches,
};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::CodexRunSnapshot;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::runtime::stop_codex_run;

pub(super) async fn settle_lifecycle_settings_drift(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
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

pub(super) async fn claim_and_settle_invalid_remote_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    authority: &TaskBoardRemoteExecutorStopAuthority,
    snapshot: &CodexRunSnapshot,
    reason: TaskBoardRemoteExecutorStopReason,
) -> Result<(), CliError> {
    let pending = db
        .claim_task_board_remote_executor_stop_pending(authority, snapshot, reason, &utc_now())
        .await?
        .ok_or_else(|| concurrent("remote executor stop authority lost its source fence"))?;
    reconcile_stop_pending(state, db, &pending).await
}

pub(super) async fn reconcile_stop_pending(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<(), CliError> {
    let snapshot = db
        .codex_run(&pending.run_id)
        .await?
        .ok_or_else(|| concurrent("stop-pending remote executor run disappeared"))?;
    if !stop_pending_snapshot_matches(pending, &snapshot) {
        return Err(concurrent(
            "stop-pending remote executor run identity changed",
        ));
    }
    if snapshot.status.is_active() {
        stop_codex_run(state, &pending.run_id).await?;
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
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message.to_string()).into()
}
