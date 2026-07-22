use tracing::warn;

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::task_board_managed_agents::{
    maintain_task_board_dispatch_claim, managed_worker_id, resume_worker_compensation,
    settle_claimed_task_board_worker,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{DispatchAppliedTask, DispatchFailure, DispatchFailureKind};

use super::DaemonHttpState;

pub(super) async fn start_and_complete_delivered_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
    let _heartbeat =
        maintain_task_board_dispatch_claim(db.clone(), &claim.intent_id, &claim.claim_token);
    settle_claimed_task_board_worker(state, db, claim).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "worker startup must keep successful claims while routing each failure through durable rollback"
)]
pub(super) async fn start_claimed_workers(
    state: &DaemonHttpState,
    applied: &[DispatchAppliedTask],
    db: &AsyncDaemonDb,
) -> (Vec<DispatchAppliedTask>, Vec<DispatchFailure>) {
    let mut kept = Vec::new();
    let mut failures = Vec::new();
    for task in applied {
        let mut claim = match db.claim_task_board_dispatch(&task.board_item_id).await {
            Ok(Some(claim)) => claim,
            Ok(None) => {
                record_unclaimed_outcome(
                    db,
                    task,
                    CliErrorKind::workflow_io(
                        "task-board worker start is not durably completed; recovery may own it",
                    )
                    .into(),
                    &mut kept,
                    &mut failures,
                )
                .await;
                continue;
            }
            Err(error) => {
                warn!(board_item_id = %task.board_item_id, %error, "deferred task board worker claim to recovery loop");
                record_unclaimed_outcome(db, task, error, &mut kept, &mut failures).await;
                continue;
            }
        };
        let _heartbeat =
            maintain_task_board_dispatch_claim(db.clone(), &claim.intent_id, &claim.claim_token);
        if let TaskBoardDispatchClaimAction::Compensate { reason } = &claim.action {
            let error = resume_compensating_claim(state, db, &claim, reason).await;
            failures.push(worker_failure(&claim.applied, &error));
            continue;
        }
        match settle_claimed_task_board_worker(state, db, &mut claim).await {
            Ok(_) => kept.push(claim.applied),
            Err(error) => failures.push(worker_failure(&claim.applied, &error)),
        }
    }
    (kept, failures)
}

async fn record_unclaimed_outcome(
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
    error: CliError,
    kept: &mut Vec<DispatchAppliedTask>,
    failures: &mut Vec<DispatchFailure>,
) {
    match db.task_board_dispatch_is_held(applied).await {
        Ok(true) => {
            kept.push(applied.clone());
            return;
        }
        Ok(false) => {}
        Err(status_error) => {
            failures.push(worker_failure(applied, &status_error));
            return;
        }
    }
    match db.task_board_dispatch_is_completed(applied).await {
        Ok(true) => kept.push(applied.clone()),
        Ok(false) => failures.push(worker_failure(applied, &error)),
        Err(status_error) => failures.push(worker_failure(applied, &status_error)),
    }
}

async fn resume_compensating_claim(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    reason: &str,
) -> CliError {
    let result = resume_worker_compensation(
        state,
        db,
        &claim.applied,
        &claim.intent_id,
        &claim.claim_token,
    )
    .await;
    if let Err(error) = result {
        return error;
    }
    match db
        .finalize_task_board_dispatch_compensation(
            &claim.intent_id,
            &claim.claim_token,
            &managed_worker_id(&claim.applied, &claim.intent_id),
            reason,
        )
        .await
    {
        Ok(()) => CliErrorKind::workflow_io(reason.to_string()).into(),
        Err(error) => error,
    }
}

fn worker_failure(applied: &DispatchAppliedTask, error: &CliError) -> DispatchFailure {
    DispatchFailure {
        board_item_id: applied.board_item_id.clone(),
        kind: DispatchFailureKind::WorkerSpawnFailed,
        message: error.to_string(),
    }
}
