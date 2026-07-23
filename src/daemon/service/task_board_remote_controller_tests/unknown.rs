use std::sync::atomic::{AtomicUsize, Ordering};

use crate::daemon::db::{
    RemoteControllerFixture, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
    accept_remote_controller, claim_remote_controller, remote_controller_fixture,
    remote_controller_running_status, remote_controller_status_request,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, RemoteSettledResponse, RemoteStatusRequest,
    RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::task_board_remote_transport::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardStatus, TaskBoardWorkflowStatus,
};

const HOST: &str = "executor-a";
const STATUS_AT: &str = "2026-07-19T10:02:01Z";
const SETTLED_AT: &str = "2026-07-19T10:02:02Z";
const CLEANED_AT: &str = "2026-07-19T10:02:03Z";

#[tokio::test]
async fn recovered_unknown_observation_settles_then_cleans_without_resuming_or_replaying_io() {
    let (fixture, unknown) = recovered_unknown_fixture().await;
    let calls = UnknownCalls::default();

    assert!(
        drive_unknown_once(&fixture, &unknown, &calls)
            .await
            .expect("settle authenticated Unknown observation")
    );
    assert_eq!(calls.status.load(Ordering::SeqCst), 1);
    assert_eq!(calls.settle.load(Ordering::SeqCst), 1);
    assert_eq!(calls.cleanup.load(Ordering::SeqCst), 0);
    assert_recovered_unknown(&fixture).await;

    let settled = load_assignment(&fixture).await;
    assert!(
        drive_unknown_once(&fixture, &settled, &calls)
            .await
            .expect("cleanup settled Unknown generation")
    );
    assert_eq!(calls.status.load(Ordering::SeqCst), 1);
    assert_eq!(calls.settle.load(Ordering::SeqCst), 1);
    assert_eq!(calls.cleanup.load(Ordering::SeqCst), 1);
    assert_recovered_unknown(&fixture).await;

    let cleaned = load_assignment(&fixture).await;
    assert!(
        !drive_unknown_once(&fixture, &cleaned, &calls)
            .await
            .expect("replay completed Unknown cleanup")
    );
    assert_eq!(calls.status.load(Ordering::SeqCst), 1);
    assert_eq!(calls.settle.load(Ordering::SeqCst), 1);
    assert_eq!(calls.cleanup.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn recovered_unknown_transient_status_failure_retries_before_any_settlement() {
    let (fixture, unknown) = recovered_unknown_fixture().await;
    let calls = UnknownCalls::default();
    let error = super::super::poll_unknown_assignment_with(
        &fixture.db,
        &unknown,
        |_| async { Err(CliErrorKind::workflow_io("temporary status failure").into()) },
        |_| async { Ok(true) },
    )
    .await
    .expect_err("transient Unknown status failure remains retryable");
    assert!(error.to_string().contains("temporary status failure"));
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&unknown.assignment_id)
            .await
            .expect("load premature settlement receipt")
            .is_none()
    );
    assert_eq!(calls.settle.load(Ordering::SeqCst), 0);
    assert_eq!(calls.cleanup.load(Ordering::SeqCst), 0);
    assert!(
        drive_unknown_once(&fixture, &unknown, &calls)
            .await
            .expect("retry Unknown status after transient failure")
    );
    assert_eq!(calls.status.load(Ordering::SeqCst), 1);
    assert_eq!(calls.settle.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn changed_unknown_observation_keeps_its_status_trust_unconsumed() {
    let (fixture, unknown) = recovered_unknown_fixture().await;
    let request = remote_controller_status_request(&fixture.request, &unknown);
    let mut response = unknown_status(&request, &unknown);
    response.workspace_ref = Some("changed-workspace".into());
    let response = response.seal().expect("reseal changed Unknown status");
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&request, HOST)
            .await
            .expect("claim changed Unknown status authority")
    );
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("reject changed Unknown status evidence"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    let current = load_assignment(&fixture).await;
    assert_eq!(
        current.state,
        crate::task_board::TaskBoardRemoteAssignmentState::Unknown
    );
    assert_eq!(
        current
            .controller_operation
            .as_ref()
            .map(|operation| operation.kind.as_str()),
        Some("status")
    );
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&unknown.assignment_id)
            .await
            .expect("load changed-evidence settlement receipt")
            .is_none()
    );
}

#[derive(Default)]
struct UnknownCalls {
    status: AtomicUsize,
    settle: AtomicUsize,
    cleanup: AtomicUsize,
}

async fn recovered_unknown_fixture() -> (RemoteControllerFixture, TaskBoardRemoteAssignmentRecord) {
    let fixture = remote_controller_fixture(1).await;
    let accepted = accept_remote_controller(&fixture).await;
    let claimed = claim_remote_controller(&fixture, &accepted).await;
    let request = remote_controller_status_request(&fixture.request, &claimed);
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&request, HOST)
            .await
            .expect("claim running fixture status authority")
    );
    fixture
        .db
        .record_task_board_remote_assignment_status(
            &request,
            &remote_controller_running_status(&request, &claimed),
            HOST,
        )
        .await
        .expect("record running fixture status");
    fixture
        .db
        .update_task_board_item(&fixture.execution.item_id, |item| {
            item.status = TaskBoardStatus::InProgress;
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            item.workflow.execution_id = Some(fixture.execution.execution_id.clone());
            Ok(true)
        })
        .await
        .expect("attach recovered fixture item")
        .expect("update recovered fixture item");
    let recovery = fixture
        .db
        .recover_task_board_remote_assignments("2026-07-19T10:02:00Z")
        .await
        .expect("recover fixture to Unknown");
    assert!(recovery.failures.is_empty(), "{recovery:?}");
    let unknown = load_assignment(&fixture).await;
    assert_eq!(
        unknown.state,
        crate::task_board::TaskBoardRemoteAssignmentState::Unknown
    );
    (fixture, unknown)
}

async fn drive_unknown_once(
    fixture: &RemoteControllerFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    calls: &UnknownCalls,
) -> Result<bool, CliError> {
    let db = &fixture.db;
    let observed = assignment.clone();
    let status_calls = &calls.status;
    let cleanup_calls = &calls.cleanup;
    let settle_calls = &calls.settle;
    super::super::poll_unknown_assignment_with(
        db,
        assignment,
        move |request| {
            let response = unknown_status(&request, &observed);
            async move {
                status_calls.fetch_add(1, Ordering::SeqCst);
                if !db
                    .claim_task_board_remote_status_io_authority(&request, HOST)
                    .await?
                {
                    return Err(CliErrorKind::concurrent_modification(
                        "Unknown status lost its exact authority",
                    )
                    .into());
                }
                db.record_task_board_remote_assignment_status(&request, &response, HOST)
                    .await
                    .map(|_| ())
            }
        },
        move |current| async move {
            super::super::terminal::finish_terminal_assignment_with(
                db,
                &current,
                || async { Ok(()) },
                move |request| async move {
                    cleanup_calls.fetch_add(1, Ordering::SeqCst);
                    record_cleanup(db, &request).await.map(|()| true)
                },
                move |request| async move {
                    settle_calls.fetch_add(1, Ordering::SeqCst);
                    record_settlement(db, &request).await
                },
            )
            .await
        },
    )
    .await
}

fn unknown_status(
    request: &RemoteStatusRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusResponse {
    let mut response = remote_controller_running_status(request, assignment);
    response.state = RemoteAssignmentWireState::Unknown;
    response.observed_at = STATUS_AT.into();
    response.seal().expect("seal Unknown status")
}

async fn record_settlement(
    db: &crate::daemon::db::AsyncDaemonDb,
    request: &RemoteSettledRequest,
) -> Result<(), CliError> {
    assert!(
        db.claim_task_board_remote_settlement_io_authority(request, HOST, SETTLED_AT)
            .await?
            .is_none()
    );
    let response = RemoteSettledResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        settlement_request_sha256: request.request_sha256.clone(),
        settled_at: SETTLED_AT.into(),
    };
    db.record_task_board_remote_settlement_response(request, &response, HOST)
        .await
        .map(|_| ())
}

async fn record_cleanup(
    db: &crate::daemon::db::AsyncDaemonDb,
    request: &RemoteCleanupObservationRequest,
) -> Result<(), CliError> {
    let trust = db.task_board_remote_host_trust_fence(HOST).await?;
    assert!(
        db.claim_task_board_remote_cleanup_observation_fenced(request, HOST, &trust)
            .await?
            .is_none()
    );
    let response = RemoteCleanupObservationResponse::for_completed(request, CLEANED_AT.into())
        .map_err(|error| CliErrorKind::workflow_io(format!("seal cleanup response: {error}")))?;
    db.record_task_board_remote_cleanup_observation(request, &response, HOST, &trust)
        .await
        .map(|_| ())
}

async fn load_assignment(fixture: &RemoteControllerFixture) -> TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load recovered Unknown assignment")
        .expect("recovered Unknown assignment exists")
}

async fn assert_recovered_unknown(fixture: &RemoteControllerFixture) {
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load recovered Unknown parent")
        .expect("recovered Unknown parent exists");
    let item = fixture
        .db
        .task_board_item(&fixture.execution.item_id)
        .await
        .expect("load recovered Unknown item");
    assert_eq!(
        parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(item.status, TaskBoardStatus::HumanRequired);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Paused);
}
