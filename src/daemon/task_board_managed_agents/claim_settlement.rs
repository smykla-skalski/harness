use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardWorkerStartError, ensure_spawn_kill_switch_clear, launch_capability,
    managed_admission_owner_id, managed_worker_id, probe_existing_worker,
    recover_same_applied_worker, start_worker_for_applied_task_in_lane, stop_worker_in_lane,
    validate_workflow_launch,
};

pub(crate) async fn settle_claimed_task_board_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
    if is_workflow_dispatch(claim) {
        return settle_workflow_before_start(state, db, claim).await;
    }
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
        Ok(()) => Ok(Some(worker)),
        Err(error) => {
            if completion_was_committed(db, claim).await? {
                claim.applied.item = db.task_board_item(&claim.applied.board_item_id).await?;
                Ok(Some(worker))
            } else {
                compensate_settlement_failure(state, db, claim, &worker_id, error).await
            }
        }
    }
}

async fn settle_workflow_before_start(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &mut ClaimedTaskBoardDispatch,
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
    let worker_id = managed_worker_id(&claim.applied, &claim.intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&claim.applied.session_id, &worker_id)
        .await;
    let existing = probe_existing_worker(state, &claim.applied, &worker_id)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "workflow worker recovery probe was uncertain: {error}"
            ))
        })?
        .map(|snapshot| recover_same_applied_worker(snapshot, &claim.applied))
        .transpose()?;
    if existing.is_none()
        && let Err(error) = authorize_workflow_start(state, db, claim).await
    {
        rollback_unstarted_workflow(db, claim, &error).await?;
        return Err(error);
    }
    if let Err(error) = validate_worker_settlement(db, claim).await {
        if existing.is_some() {
            return compensate_settlement_failure(state, db, claim, &worker_id, error).await;
        }
        return Err(error);
    }
    match db
        .prepare_task_board_workflow_dispatch(&claim.intent_id, &claim.claim_token)
        .await
    {
        Ok(item) => {
            claim.applied.item = item;
            Ok(existing)
        }
        Err(error) if existing.is_some() => {
            compensate_settlement_failure(state, db, claim, &worker_id, error).await
        }
        Err(error) => {
            rollback_unstarted_workflow(db, claim, &error).await?;
            Err(error)
        }
    }
}

async fn authorize_workflow_start(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
) -> Result<(), CliError> {
    ensure_spawn_kill_switch_clear(state, &claim.applied.board_item_id).await?;
    let revision_fence = validate_workflow_launch(state, &claim.applied).await?;
    #[cfg(test)]
    super::start_authorization_test_support::pause_before_final_authorization().await;
    db.validate_task_board_dispatch_admission_start(
        &claim.intent_id,
        &claim.claim_token,
        launch_capability(claim.applied.item.agent_mode),
        revision_fence,
    )
    .await
}

async fn rollback_unstarted_workflow(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    error: &CliError,
) -> Result<(), CliError> {
    db.fail_task_board_dispatch(
        &claim.intent_id,
        &claim.claim_token,
        claim.consumed_approval_grant_id.as_deref(),
        &error.to_string(),
    )
    .await
}

fn is_workflow_dispatch(claim: &ClaimedTaskBoardDispatch) -> bool {
    claim.applied.read_only_workflow.is_some() || claim.applied.write_workflow.is_some()
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
        claim.applied.read_only_workflow.is_some() || claim.applied.write_workflow.is_some(),
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
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
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
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
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
