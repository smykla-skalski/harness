use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::accept_controller;
use super::remote_assignment_test_support::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLease, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn controller_cancel_response_is_fenced_and_exactly_replayed() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = cancel_request(
        &fixture,
        accepted.lease_id.as_deref().expect("accepted lease"),
    );
    let response = cancel_response(&fixture, &request);
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:02Z")
        .await
        .expect("claim cancel authority")
        .expect("cancel remains active");
    let cancelled = fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("persist cancel response");
    assert!(matches!(
        cancelled,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
                && record.last_mutation_kind.as_deref() == Some("cancel_response")
                && record.completed_at.as_deref() == Some(CLAIMED_AT)
                && record.error.as_deref() == Some("operator requested cancellation")
    ));
    assert_cancel_replay_is_exact(&fixture, &request, &response).await;
}

#[tokio::test]
async fn claimed_cancel_without_immutable_claim_receipt_is_stale_without_mutation() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = cancel_request(
        &fixture,
        accepted.lease_id.as_deref().expect("accepted lease"),
    );
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:02Z")
        .await
        .expect("claim cancel authority")
        .expect("cancel remains active");
    let before = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load assignment before invalid response")
        .expect("assignment exists");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    let response = claimed_cancel_response(&fixture, &request);

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_cancel(
                &request,
                &response,
                HOST,
                "2026-07-19T10:00:11Z",
            )
            .await
            .expect("reject claimed cancel without receipt"),
        TaskBoardRemoteMutationOutcome::Stale(record) if record == before
    ));
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("reload assignment after invalid response")
            .expect("assignment exists"),
        before
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence"),
        sequence
    );
}

#[tokio::test]
async fn claimed_cancel_with_immutable_claim_receipt_is_exactly_replayed() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let lease_id = accepted.lease_id.as_deref().expect("accepted lease");
    persist_claim_receipt(&fixture, lease_id).await;
    let request = cancel_request(&fixture, lease_id);
    let response = claimed_cancel_response(&fixture, &request);
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:10Z")
        .await
        .expect("claim cancel authority")
        .expect("cancel remains active");

    let cancelled = fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("persist claimed cancel response");
    assert!(matches!(
        cancelled,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
                && record.claim_receipt.is_some()
                && record.claimed_at.as_deref() == Some(CLAIMED_AT)
    ));
    assert_cancel_replay_is_exact(&fixture, &request, &response).await;
}

#[tokio::test]
async fn claimed_cancel_response_preserves_durable_claim_evidence() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let lease_id = accepted.lease_id.as_deref().expect("accepted lease");
    persist_claim_receipt(&fixture, lease_id).await;
    let request = cancel_request(&fixture, lease_id);
    // An executor that claimed but never started reports an empty cancel: the durable
    // claim is preserved (never erased) while the assignment terminates.
    let response = cancel_response(&fixture, &request);
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:10Z")
        .await
        .expect("claim omitted-evidence cancellation")
        .expect("omitted-evidence cancellation remains active");

    let cancelled = fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("cancel preserves the durable claim");
    assert!(matches!(
        cancelled,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
                && record.claim_receipt.is_some()
                && record.claimed_at.as_deref() == Some(CLAIMED_AT)
                && record.started_at.is_none()
                && record.workspace_ref.is_none()
    ));
    assert_cancel_replay_is_exact(&fixture, &request, &response).await;
}

#[tokio::test]
async fn claimed_cancel_response_cannot_change_durable_run_evidence() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let lease_id = accepted.lease_id.as_deref().expect("accepted lease");
    persist_claim_receipt(&fixture, lease_id).await;
    let request = cancel_request(&fixture, lease_id);
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:10Z")
        .await
        .expect("claim conflicting-evidence cancellation")
        .expect("conflicting-evidence cancellation remains active");
    let before = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load claimed assignment")
        .expect("claimed assignment exists");
    let parent_before = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load parent")
        .expect("parent exists");
    let item_before = fixture
        .db
        .task_board_item(&fixture.execution.item_id)
        .await
        .expect("load item");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");

    for response in conflicting_cancel_responses(&fixture, &request) {
        assert!(matches!(
            fixture
                .db
                .record_task_board_remote_assignment_cancel(
                    &request,
                    &response,
                    HOST,
                    "2026-07-19T10:00:21Z",
                )
                .await
                .expect("reject conflicting durable run evidence"),
            TaskBoardRemoteMutationOutcome::Stale(record) if record == before
        ));
    }
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("reload assignment")
            .expect("assignment exists"),
        before
    );
    assert_eq!(
        fixture
            .db
            .task_board_workflow_execution(&fixture.execution.execution_id)
            .await
            .expect("reload parent")
            .expect("parent exists"),
        parent_before
    );
    assert_eq!(
        fixture
            .db
            .task_board_item(&fixture.execution.item_id)
            .await
            .expect("reload item"),
        item_before
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence"),
        sequence
    );
}

fn cancel_request(fixture: &ControllerFixture, lease_id: &str) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "operator requested cancellation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel request")
}

fn cancel_response(
    fixture: &ControllerFixture,
    request: &RemoteCancelRequest,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        observed_at: CLAIMED_AT.into(),
    }
    .seal(request)
    .expect("seal cancel response")
}

fn claimed_cancel_response(
    fixture: &ControllerFixture,
    request: &RemoteCancelRequest,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: None,
        workspace_ref: None,
        observed_at: "2026-07-19T10:00:10Z".into(),
    }
    .seal(request)
    .expect("seal claimed cancel response")
}

fn conflicting_cancel_responses(
    fixture: &ControllerFixture,
    request: &RemoteCancelRequest,
) -> [RemoteCancelResponse; 2] {
    let conflicting_claim = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: Some("2026-07-19T10:00:11Z".into()),
        started_at: None,
        workspace_ref: None,
        observed_at: "2026-07-19T10:00:20Z".into(),
    }
    .seal(request)
    .expect("seal conflicting claim response");
    let conflicting_start = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some("2026-07-19T10:00:15Z".into()),
        workspace_ref: Some("workspace-conflict".into()),
        observed_at: "2026-07-19T10:00:20Z".into(),
    }
    .seal(request)
    .expect("seal conflicting start response");
    [conflicting_claim, conflicting_start]
}

async fn persist_claim_receipt(fixture: &ControllerFixture, lease_id: &str) {
    let request = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim request");
    let response = RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: lease_id.into(),
            expires_at: LEASE_EXPIRES.into(),
        },
        claimed_at: CLAIMED_AT.into(),
    };
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&request, HOST, "2026-07-19T10:00:02Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    fixture
        .db
        .record_task_board_remote_assignment_claim(&request, &response, HOST, CLAIMED_AT)
        .await
        .expect("persist immutable claim receipt");
}

async fn assert_cancel_replay_is_exact(
    fixture: &ControllerFixture,
    request: &RemoteCancelRequest,
    response: &RemoteCancelResponse,
) {
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_cancel(
                request,
                response,
                HOST,
                "2026-07-19T10:00:12Z",
            )
            .await
            .expect("replay cancel response"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    let mut conflicting = response.clone();
    conflicting.observed_at = "2026-07-19T10:00:13Z".into();
    let conflicting = conflicting
        .seal(request)
        .expect("seal conflicting cancel response");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_cancel(
                request,
                &conflicting,
                HOST,
                "2026-07-19T10:00:14Z",
            )
            .await
            .expect("reject conflicting cancel response"),
        TaskBoardRemoteMutationOutcome::Stale(record)
            if record.completed_at.as_deref() == Some(CLAIMED_AT)
    ));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence"),
        sequence
    );
}
