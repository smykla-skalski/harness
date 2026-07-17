use tracing::warn;

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::task_board_managed_agents::{
    TaskBoardWorkerStartError, begin_worker_compensation, maintain_task_board_dispatch_claim,
    managed_admission_owner_id, managed_worker_id, resume_worker_compensation,
    start_worker_for_applied_task,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{DispatchAppliedTask, DispatchFailure, DispatchFailureKind};

use super::DaemonHttpState;

pub(super) async fn start_and_complete_delivered_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<ManagedAgentSnapshot, CliError> {
    let _heartbeat =
        maintain_task_board_dispatch_claim(db.clone(), &claim.intent_id, &claim.claim_token);
    let agent = match start_worker_for_applied_task(
        state,
        &claim.applied,
        &claim.intent_id,
        &claim.claim_token,
    )
    .await
    {
        Ok(agent) => agent,
        Err(start_error) => {
            let may_rollback = start_error.may_rollback();
            let error = start_error.into_cli_error();
            if may_rollback {
                db.fail_task_board_dispatch(
                    &claim.intent_id,
                    &claim.claim_token,
                    claim.consumed_approval_grant_id.as_deref(),
                    &error.to_string(),
                )
                .await?;
            }
            return Err(error);
        }
    };
    if let Err(error) = ensure_started_claim_current(db, claim).await {
        return match compensate_started_worker(state, db, claim, &error).await {
            Ok(()) => Err(error),
            Err(compensation_error) => Err(compensation_error),
        };
    }
    match complete_started_worker(db, claim).await {
        Ok(()) => Ok(agent),
        Err(error) => match compensate_started_worker(state, db, claim, &error).await {
            Ok(()) => Err(error),
            Err(compensation_error) => Err(compensation_error),
        },
    }
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
        match start_worker_for_applied_task(
            state,
            &claim.applied,
            &claim.intent_id,
            &claim.claim_token,
        )
        .await
        {
            Ok(_) => {
                if let Err(error) = ensure_started_claim_current(db, &claim).await {
                    let message = compensate_started_worker(state, db, &claim, &error)
                        .await
                        .err()
                        .unwrap_or(error);
                    failures.push(worker_failure(&claim.applied, &message));
                    continue;
                }
                if let Err(error) = complete_started_worker(db, &mut claim).await {
                    let message = compensate_started_worker(state, db, &claim, &error)
                        .await
                        .err()
                        .unwrap_or(error);
                    failures.push(worker_failure(&claim.applied, &message));
                    continue;
                }
                kept.push(claim.applied);
            }
            Err(error) => record_worker_failure(db, claim, error, &mut failures).await,
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

async fn complete_started_worker(
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<(), CliError> {
    claim.applied.item = db
        .complete_task_board_dispatch(
            &claim.intent_id,
            &claim.claim_token,
            &managed_admission_owner_id(&claim.applied, &claim.intent_id),
        )
        .await?;
    Ok(())
}

async fn compensate_started_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    completion_error: &CliError,
) -> Result<(), CliError> {
    begin_worker_compensation(
        state,
        db,
        &claim.applied,
        &claim.intent_id,
        &claim.claim_token,
        &completion_error.to_string(),
    )
        .await
        .map_err(|stop_error| {
            CliErrorKind::workflow_io(format!(
                "task-board worker intent completion failed ({completion_error}); compensation failed ({stop_error}); the claim remains for recovery"
            ))
        })?;
    db.finalize_task_board_dispatch_compensation(
        &claim.intent_id,
        &claim.claim_token,
        claim.consumed_approval_grant_id.as_deref(),
        &managed_worker_id(&claim.applied, &claim.intent_id),
        &completion_error.to_string(),
    )
    .await
    .map_err(|rollback_error| {
        CliErrorKind::workflow_io(format!(
            "task-board worker stopped after intent completion failed ({completion_error}), but rollback failed ({rollback_error})"
        ))
        .into()
    })
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
            claim.consumed_approval_grant_id.as_deref(),
            &managed_worker_id(&claim.applied, &claim.intent_id),
            reason,
        )
        .await
    {
        Ok(()) => CliErrorKind::workflow_io(reason.to_string()).into(),
        Err(error) => error,
    }
}

async fn ensure_started_claim_current(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
) -> Result<(), CliError> {
    db.renew_task_board_dispatch_claim(&claim.intent_id, &claim.claim_token)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "task-board worker started, but dispatch claim '{}' is no longer current: {error}; leaving the worker and claim for recovery",
                claim.intent_id
            ))
            .into()
        })
}

async fn record_worker_failure(
    db: &AsyncDaemonDb,
    claim: ClaimedTaskBoardDispatch,
    start_error: TaskBoardWorkerStartError,
    failures: &mut Vec<DispatchFailure>,
) {
    let may_rollback = start_error.may_rollback();
    let error = start_error.into_cli_error();
    if may_rollback {
        let rollback = db
            .fail_task_board_dispatch(
                &claim.intent_id,
                &claim.claim_token,
                claim.consumed_approval_grant_id.as_deref(),
                &error.to_string(),
            )
            .await;
        log_rollback_outcome(&claim.applied.board_item_id, rollback.err());
    }
    failures.push(worker_failure(&claim.applied, &error));
}

fn worker_failure(applied: &DispatchAppliedTask, error: &CliError) -> DispatchFailure {
    DispatchFailure {
        board_item_id: applied.board_item_id.clone(),
        kind: DispatchFailureKind::WorkerSpawnFailed,
        message: error.to_string(),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_rollback_outcome(board_item_id: &str, undo_error: Option<CliError>) {
    if let Some(error) = undo_error {
        warn!(
            board_item_id,
            error = %error,
            "failed to roll back dispatched task-board item after worker spawn failure",
        );
    }
}
