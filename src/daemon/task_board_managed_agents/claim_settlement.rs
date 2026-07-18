use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardWorkerStartError, managed_admission_owner_id, managed_worker_id,
    start_worker_for_applied_task_in_lane, stop_worker_in_lane,
};

pub(crate) async fn settle_claimed_task_board_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<ManagedAgentSnapshot, CliError> {
    let worker_id = managed_worker_id(&claim.applied, &claim.intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&claim.applied.session_id, &worker_id)
        .await;
    let worker = match start_worker_for_applied_task_in_lane(
        state,
        &claim.applied,
        &claim.intent_id,
        &claim.claim_token,
        &worker_id,
    )
    .await
    {
        Ok(worker) => worker,
        Err(error) => return handle_start_error(db, claim, error).await,
    };
    if let Err(error) = validate_worker_settlement(db, claim).await {
        return compensate_settlement_failure(state, db, claim, &worker_id, error).await;
    }
    match complete_worker_settlement(db, claim).await {
        Ok(()) => Ok(worker),
        Err(error) => {
            if completion_was_committed(db, claim).await? {
                claim.applied.item = db.task_board_item(&claim.applied.board_item_id).await?;
                Ok(worker)
            } else {
                compensate_settlement_failure(state, db, claim, &worker_id, error).await
            }
        }
    }
}

async fn validate_worker_settlement(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
) -> Result<(), CliError> {
    db.renew_task_board_dispatch_claim(&claim.intent_id, &claim.claim_token)
        .await
}

async fn complete_worker_settlement(
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

async fn completion_was_committed(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
) -> Result<bool, CliError> {
    let Some(execution_id) = claim.applied.item.workflow.execution_id.as_deref() else {
        return Ok(false);
    };
    let admission_owner = managed_admission_owner_id(&claim.applied, &claim.intent_id);
    let worker_id = managed_worker_id(&claim.applied, &claim.intent_id);
    db.task_board_dispatch_completion_matches(
        &claim.intent_id,
        execution_id,
        &admission_owner,
        &admission_owner,
        &worker_id,
        claim.applied.read_only_workflow.is_some(),
    )
        .await
        .map_err(|status_error| {
            CliErrorKind::workflow_io(format!(
                "task-board worker completion was ambiguous and its durable status could not be verified: {status_error}; leaving the claim fenced"
            ))
            .into()
        })
}

async fn handle_start_error(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    start_error: TaskBoardWorkerStartError,
) -> Result<ManagedAgentSnapshot, CliError> {
    let may_rollback = start_error.may_rollback();
    let error = start_error.into_cli_error();
    if may_rollback {
        db.fail_task_board_dispatch(
            &claim.intent_id,
            &claim.claim_token,
            claim.consumed_approval_grant_id.as_deref(),
            &error.to_string(),
        )
        .await
        .map_err(|rollback_error| {
            CliErrorKind::workflow_io(format!(
                "task-board worker start failed ({error}); dispatch rollback failed ({rollback_error})"
            ))
        })?;
    }
    Err(error)
}

async fn compensate_settlement_failure(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    worker_id: &str,
    error: CliError,
) -> Result<ManagedAgentSnapshot, CliError> {
    db.begin_task_board_dispatch_compensation(
        &claim.intent_id,
        &claim.claim_token,
        worker_id,
        &error.to_string(),
    )
    .await
    .map_err(|compensation_error| settlement_compensation_error(&error, &compensation_error))?;
    stop_worker_in_lane(state, &claim.applied, worker_id.to_string())
        .await
        .map_err(|compensation_error| settlement_compensation_error(&error, &compensation_error))?;
    db.finalize_task_board_dispatch_compensation(
        &claim.intent_id,
        &claim.claim_token,
        worker_id,
        &error.to_string(),
    )
    .await
    .map_err(|compensation_error| settlement_compensation_error(&error, &compensation_error))?;
    Err(error)
}

fn settlement_compensation_error(settlement: &CliError, compensation: &CliError) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board worker settlement failed ({settlement}); compensation failed ({compensation}); the durable claim remains fenced"
    ))
    .into()
}
