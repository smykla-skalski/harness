use sqlx::query_as;

use super::remote_assignment_cancel_journal::pending_cancel_request_for_record;
use super::remote_assignment_generation_tests::{accept_controller, status_request};
use super::remote_assignment_test_support::{
    ControllerFixture, HOST, LEASE_EXPIRES, controller_fixture,
};
use super::{TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteCancelRequest, RemoteLease,
    RemoteStatusRequest, RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState,
};

const REQUESTED_AT: &str = "2026-07-19T10:00:02Z";
const CANCELLED_AT: &str = "2026-07-19T10:00:12Z";
const REASON: &str = "operator requested cancellation";

#[tokio::test]
async fn journaled_cancel_status_survives_restart_and_projects_before_cleanup() {
    let fixture = controller_fixture(1).await;
    let (assignment, cancel) = pending_cancel(&fixture).await;
    assert_eq!(
        pending_cancel_request_for_record(&assignment)
            .expect("decode pending cancel")
            .expect("pending cancel"),
        cancel
    );

    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("controller.db"))
        .await
        .expect("reopen controller database");
    let durable = reopened
        .task_board_remote_assignment(&assignment.assignment_id)
        .await
        .expect("load restarted cancel journal")
        .expect("restarted assignment");
    assert_eq!(
        pending_cancel_request_for_record(&durable)
            .expect("reconstruct restarted cancel")
            .expect("restarted pending cancel"),
        cancel
    );

    let status_request = status_request(&fixture.request, &durable);
    assert!(
        reopened
            .claim_task_board_remote_status_io_authority(&status_request, HOST)
            .await
            .expect("claim cancel reconciliation status")
    );
    let response = cancelled_status(&status_request, &durable, REASON);
    let outcome = reopened
        .record_task_board_remote_assignment_status(&status_request, &response, HOST)
        .await
        .expect("reconcile pending cancel status");
    let TaskBoardRemoteMutationOutcome::Updated(cancelled) = outcome else {
        panic!("expected updated cancellation, got {outcome:?}");
    };
    assert_eq!(cancelled.state, TaskBoardRemoteAssignmentState::Cancelled);
    assert_eq!(cancelled.cancel_requested_at.as_deref(), Some(REQUESTED_AT));
    assert_eq!(cancelled.error.as_deref(), Some(REASON));
    assert!(cancelled.controller_operation.is_none());
    assert_eq!(cancelled.status_response.as_ref(), Some(&response));

    let parent = reopened
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load projected parent")
        .expect("projected parent");
    assert_eq!(
        parent.transition.execution_state,
        TaskBoardExecutionState::Cancelled
    );
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Cancelled);
    assert!(
        !parent
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE)
    );
    assert_terminal_projection(&reopened, &cancelled).await;
    assert!(
        !reopened
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load active assignment fence")
    );
    assert!(
        reopened
            .task_board_remote_settlement_receipt(&cancelled.assignment_id)
            .await
            .expect("load settlement receipt")
            .is_none()
    );
    assert!(cancelled.cleanup_completed_at.is_none());
}

#[tokio::test]
async fn wrong_cancel_status_evidence_performs_zero_mutation() {
    let fixture = controller_fixture(1).await;
    let (before, _) = pending_cancel(&fixture).await;
    let request = status_request(&fixture.request, &before);
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&request, HOST)
            .await
            .expect("claim reconciliation status")
    );
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load parent before stale evidence")
        .expect("parent before stale evidence");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load sequence before stale evidence");

    let wrong_reason = cancelled_status(&request, &before, "different cancellation");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &wrong_reason, HOST)
            .await
            .expect("reject wrong cancel reason"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    let mut wrong_epoch_request = request.clone();
    wrong_epoch_request.binding.fencing_epoch += 1;
    let wrong_epoch_request = wrong_epoch_request.seal().expect("seal wrong epoch status");
    let wrong_epoch = cancelled_status(&wrong_epoch_request, &before, REASON);
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(
                &wrong_epoch_request,
                &wrong_epoch,
                HOST,
            )
            .await
            .expect("reject wrong cancel epoch"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    let exact = cancelled_status(&request, &before, REASON);
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &exact, "other-principal")
            .await
            .expect("reject wrong cancel principal"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert_unchanged(&fixture, &before, &parent, sequence).await;
}

#[tokio::test]
async fn cancel_status_cannot_cross_host_trust_rotation() {
    let fixture = controller_fixture(1).await;
    let (before, _) = pending_cancel(&fixture).await;
    rotate_host_trust(&fixture).await;
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load parent before trust rejection")
        .expect("parent before trust rejection");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load sequence after trust rotation");
    let request = status_request(&fixture.request, &before);
    let response = cancelled_status(&request, &before, REASON);
    let error = fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect_err("rotated trust must reject cancel status");
    assert!(
        error
            .to_string()
            .contains("remote lifecycle transport trust changed from the frozen generation"),
        "{error}"
    );
    assert_unchanged(&fixture, &before, &parent, sequence).await;
}

async fn pending_cancel(
    fixture: &ControllerFixture,
) -> (TaskBoardRemoteAssignmentRecord, RemoteCancelRequest) {
    let accepted = accept_controller(fixture).await;
    let request = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.expect("accepted lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: REASON.into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel request");
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, REQUESTED_AT)
        .await
        .expect("claim cancel authority")
        .expect("cancel remains active");
    let assignment = fixture
        .db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load pending cancel")
        .expect("pending cancel assignment");
    (assignment, request)
}

fn cancelled_status(
    request: &RemoteStatusRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
    reason: &str,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Cancelled,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: assignment
                .lease_expires_at
                .clone()
                .unwrap_or_else(|| LEASE_EXPIRES.into()),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: assignment.claimed_at.clone(),
        started_at: assignment.started_at.clone(),
        workspace_ref: assignment.workspace_ref.clone(),
        error_code: Some(reason.into()),
        failure_class: None,
        observed_at: CANCELLED_AT.into(),
    }
    .seal()
    .expect("seal cancelled status")
}

async fn rotate_host_trust(fixture: &ControllerFixture) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    settings.execution_hosts[0].certificate_fingerprint =
        crate::task_board::remote_spki_pin::encode([0xbb; 32]);
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("rotate host trust");
}

async fn assert_terminal_projection(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
) {
    let handoff = query_as::<_, (String, Option<String>, Option<String>)>(
        "SELECT controller_handoff_kind, cleanup_settlement_request_sha256,
                cleanup_completed_at
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&assignment.assignment_id)
    .fetch_one(db.pool())
    .await
    .expect("load terminal projection handoff");
    assert_eq!(handoff, ("terminal_projection".into(), None, None));
}

async fn assert_unchanged(
    fixture: &ControllerFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    sequence: i64,
) {
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment(&assignment.assignment_id)
            .await
            .expect("reload unchanged assignment")
            .expect("unchanged assignment"),
        *assignment
    );
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&fixture.execution.execution_id)
            .await
            .expect("reload unchanged parent")
            .expect("unchanged parent"),
        *parent
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("reload unchanged sequence"),
        sequence
    );
}
