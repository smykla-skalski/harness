use std::future::Future;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
    TaskBoardRemoteResultAdoptionOutcome, exact_active_remote_target, parent_points_to_assignment,
};
use crate::daemon::service::import_and_adopt_task_board_remote_implementation_result;

use crate::daemon::task_board_remote_transport::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

use super::requests;

pub(super) async fn finish_terminal_assignment(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    Box::pin(finish_terminal_assignment_with(
        db,
        assignment,
        || fetch_manifest(db, client, assignment),
        |request| async move {
            client
                .observe_cleanup(db, &request)
                .await
                .map(|outcome| outcome.is_some())
                .map_err(controller_database_error)
        },
        |request| async move {
            client
                .settle(db, &request)
                .await
                .map(|_| ())
                .map_err(controller_database_error)
        },
    ))
    .await
}

pub(super) async fn finish_terminal_assignment_with<
    FetchManifest,
    FetchFuture,
    ObserveCleanup,
    CleanupFuture,
    Settle,
    SettleFuture,
>(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    fetch_manifest: FetchManifest,
    observe_cleanup: ObserveCleanup,
    settle: Settle,
) -> Result<bool, CliError>
where
    FetchManifest: FnOnce() -> FetchFuture,
    FetchFuture: Future<Output = Result<(), CliError>>,
    ObserveCleanup: FnOnce(
        crate::daemon::task_board_remote_transport::wire_cleanup::RemoteCleanupObservationRequest,
    ) -> CleanupFuture,
    CleanupFuture: Future<Output = Result<bool, CliError>>,
    Settle: FnOnce(
        crate::daemon::task_board_remote_transport::wire::RemoteSettledRequest,
    ) -> SettleFuture,
    SettleFuture: Future<Output = Result<(), CliError>>,
{
    if assignment.cleanup_completed_at.is_some() {
        return Ok(false);
    }
    let handoff_ready = db
        .task_board_remote_assignment_has_settlement_handoff(
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?;
    if let Some(settlement) = db
        .task_board_remote_settlement_receipt(&assignment.assignment_id)
        .await?
    {
        if !handoff_ready {
            return Ok(false);
        }
        let request = requests::cleanup_observation_request(&settlement)?;
        return observe_cleanup(request).await;
    }
    if handoff_ready {
        let current = db
            .task_board_remote_assignment(&assignment.assignment_id)
            .await?
            .ok_or_else(missing_assignment)?;
        let request = requests::settlement_request(&current)?;
        settle(request).await?;
        return Ok(true);
    }
    let parent = db
        .task_board_workflow_execution(&assignment.execution_id)
        .await?
        .ok_or_else(missing_execution)?;
    match classify_terminal_handoff(db, assignment, &parent).await? {
        TerminalHandoff::Ready => {}
        TerminalHandoff::NeedsResultAdoption => {
            fetch_manifest().await?;
            if !Box::pin(adopt_terminal_result(db, assignment, &parent)).await? {
                return Ok(false);
            }
        }
        TerminalHandoff::Reject => return Ok(false),
    }
    let current = db
        .task_board_remote_assignment(&assignment.assignment_id)
        .await?
        .ok_or_else(missing_assignment)?;
    let request = requests::settlement_request(&current)?;
    settle(request).await?;
    Ok(true)
}

enum TerminalHandoff {
    Ready,
    NeedsResultAdoption,
    Reject,
}

async fn classify_terminal_handoff(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<TerminalHandoff, CliError> {
    if matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Completed | TaskBoardRemoteAssignmentState::Failed
    ) {
        return if exact_active_remote_target(parent, assignment) {
            Ok(TerminalHandoff::NeedsResultAdoption)
        } else {
            Ok(TerminalHandoff::Reject)
        };
    }
    if parent_points_to_assignment(parent, assignment) {
        return Ok(TerminalHandoff::Reject);
    }
    if !matches!(
        assignment.state,
        TaskBoardRemoteAssignmentState::Cancelled | TaskBoardRemoteAssignmentState::Superseded
    ) {
        return Ok(TerminalHandoff::Reject);
    }
    match db
        .record_task_board_remote_terminal_cleanup_handoff(
            assignment,
            &TaskBoardWorkflowExecutionCas::from(parent),
            &crate::workspace::utc_now(),
        )
        .await?
    {
        TaskBoardRemoteMutationOutcome::Updated(_)
        | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(TerminalHandoff::Ready),
        TaskBoardRemoteMutationOutcome::Stale(_) => Ok(TerminalHandoff::Reject),
    }
}

async fn adopt_terminal_result(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    let outcome = if assignment.phase == TaskBoardExecutionPhase::Implementation
        && assignment.state == TaskBoardRemoteAssignmentState::Completed
    {
        Box::pin(import_and_adopt_task_board_remote_implementation_result(
            db,
            &assignment.assignment_id,
            assignment.fencing_epoch,
        ))
        .await?
    } else {
        db.adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(parent),
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?
    };
    match outcome {
        TaskBoardRemoteResultAdoptionOutcome::Updated(_)
        | TaskBoardRemoteResultAdoptionOutcome::Replayed(_) => Ok(true),
        TaskBoardRemoteResultAdoptionOutcome::Stale(_) => Ok(false),
    }
}

async fn fetch_manifest(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let Some(status) = assignment.status_response.as_ref() else {
        return Ok(());
    };
    for artifact in &status.output_artifacts.entries {
        let request = requests::artifact_request(assignment, artifact)?;
        client
            .fetch_artifact(db, &request)
            .await
            .map_err(controller_database_error)?;
    }
    Ok(())
}

fn controller_database_error(error: RemoteExecutionControllerError) -> CliError {
    match error {
        RemoteExecutionControllerError::Database(error) => error,
        RemoteExecutionControllerError::Transport(error) => {
            CliErrorKind::workflow_io(error.to_string()).into()
        }
    }
}

fn missing_assignment() -> CliError {
    CliErrorKind::concurrent_modification(
        "remote assignment disappeared during terminal controller progression",
    )
    .into()
}

fn missing_execution() -> CliError {
    CliErrorKind::concurrent_modification(
        "remote execution disappeared during terminal controller progression",
    )
    .into()
}
