use std::future::Future;

use super::{canonical_now, controller_database_error, requests};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::task_board_remote_transport::controller::RemoteExecutionControllerClient;
use crate::daemon::task_board_remote_transport::wire::RemoteAssignmentWireState;
use crate::errors::CliError;
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) async fn poll_active_assignment(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    if let Some(cancel) = db
        .task_board_remote_cancel_intent(&assignment.assignment_id)
        .await?
    {
        return poll_cancel_intent(db, client, assignment, &cancel).await;
    }
    poll_active_assignment_with(
        assignment,
        |request| async move {
            client
                .status(db, &request)
                .await
                .map(|(_, outcome)| outcome)
                .map_err(controller_database_error)
        },
        || async move {
            db.task_board_remote_host_trust_fence(&assignment.host_id)
                .await
                .map(|trust| trust.config.enabled)
        },
        |request| async move {
            client
                .renew_lease(db, &request)
                .await
                .map(|(_, outcome)| outcome)
                .map_err(controller_database_error)
        },
        |request| async move {
            client
                .reconcile_pending_renewal(db, &request)
                .await
                .map(|(_, outcome)| outcome)
                .map_err(controller_database_error)
        },
        canonical_now,
    )
    .await
}

async fn poll_cancel_intent(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request: &crate::daemon::task_board_remote_transport::wire::RemoteCancelRequest,
) -> Result<bool, CliError> {
    let pending = assignment
        .controller_operation
        .as_ref()
        .map(|operation| operation.kind.as_str());
    if pending.is_some_and(|kind| kind != "cancel") {
        return Err(crate::errors::CliErrorKind::concurrent_modification(
            "remote cancellation intent overlaps another controller operation",
        )
        .into());
    }
    if pending == Some("cancel") {
        let status = requests::status_request(assignment)?;
        let (response, outcome) = client
            .status(db, &status)
            .await
            .map_err(controller_database_error)?;
        if matches!(
            response.state,
            RemoteAssignmentWireState::Completed
                | RemoteAssignmentWireState::Failed
                | RemoteAssignmentWireState::Cancelled
        ) {
            require_cancel_progress(outcome)?;
            return Ok(true);
        }
    }
    let (_, outcome) = client
        .cancel(db, request)
        .await
        .map_err(controller_database_error)?;
    require_cancel_progress(outcome)?;
    Ok(true)
}

fn require_cancel_progress(outcome: TaskBoardRemoteMutationOutcome) -> Result<(), CliError> {
    match outcome {
        TaskBoardRemoteMutationOutcome::Updated(_) | TaskBoardRemoteMutationOutcome::Replayed(_) => {
            Ok(())
        }
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(
            crate::errors::CliErrorKind::concurrent_modification(
                "remote cancellation lost its exact generation",
            )
            .into(),
        ),
    }
}

pub(super) async fn poll_active_assignment_with<
    Status,
    StatusFuture,
    Enabled,
    EnabledFuture,
    Renew,
    RenewFuture,
    ReplayRenew,
    ReplayRenewFuture,
    Now,
>(
    assignment: &TaskBoardRemoteAssignmentRecord,
    status: Status,
    host_enabled: Enabled,
    renew: Renew,
    replay_renew: ReplayRenew,
    now: Now,
) -> Result<bool, CliError>
where
    Status: FnOnce(
        crate::daemon::task_board_remote_transport::wire::RemoteStatusRequest,
    ) -> StatusFuture,
    StatusFuture: Future<Output = Result<TaskBoardRemoteMutationOutcome, CliError>>,
    Enabled: FnOnce() -> EnabledFuture,
    EnabledFuture: Future<Output = Result<bool, CliError>>,
    Renew: FnOnce(
        crate::daemon::task_board_remote_transport::wire::RemoteLeaseRenewRequest,
    ) -> RenewFuture,
    RenewFuture: Future<Output = Result<TaskBoardRemoteMutationOutcome, CliError>>,
    ReplayRenew: FnOnce(
        crate::daemon::task_board_remote_transport::wire::RemoteLeaseRenewRequest,
    ) -> ReplayRenewFuture,
    ReplayRenewFuture: Future<Output = Result<TaskBoardRemoteMutationOutcome, CliError>>,
    Now: FnOnce() -> String,
{
    let pending = assignment
        .controller_operation
        .as_ref()
        .map(|operation| operation.kind.as_str());
    if pending == Some("renew") {
        let outcome = replay_renew(requests::renewal_request(assignment)?).await?;
        let Some(current) = accepted_mutation_record(outcome) else {
            return Err(crate::errors::CliErrorKind::concurrent_modification(
                "pending remote lease renewal could not be reconciled",
            )
            .into());
        };
        status(requests::status_request(&current)?).await?;
        return Ok(true);
    }

    let outcome = status(requests::status_request(assignment)?).await?;
    if pending == Some("cancel") {
        return Ok(true);
    }
    let Some(current) = accepted_mutation_record(outcome) else {
        return Ok(true);
    };
    if !matches!(
        current.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    ) || !host_enabled().await?
        || !requests::renewal_is_due(&current, &now())?
    {
        return Ok(true);
    }
    renew(requests::renewal_request(&current)?).await?;
    Ok(true)
}

fn accepted_mutation_record(
    outcome: TaskBoardRemoteMutationOutcome,
) -> Option<TaskBoardRemoteAssignmentRecord> {
    match outcome {
        TaskBoardRemoteMutationOutcome::Updated(record)
        | TaskBoardRemoteMutationOutcome::Replayed(record) => Some(record),
        TaskBoardRemoteMutationOutcome::Stale(_) => None,
    }
}
