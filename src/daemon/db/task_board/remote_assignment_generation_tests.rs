use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_test_support::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteClaimResponse, RemoteLease,
    RemoteLeaseRenewRequest, RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferResponse,
    RemoteStatusRequest, RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn controller_offer_rejects_a_caller_supplied_lease_outside_the_sealed_duration() {
    let fixture = controller_fixture(1).await;

    let error = fixture
        .db
        .offer_task_board_remote_assignment(
            &crate::task_board::TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &crate::task_board::TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &fixture.request,
            HOST,
            NOW,
            "2026-07-19T10:01:01Z",
            DEADLINE,
        )
        .await
        .expect_err("caller cannot widen the sealed assignment lease");

    assert!(
        error
            .to_string()
            .contains("exactly match the sealed duration")
    );
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("load assignment")
            .is_none()
    );
    let execution = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load execution")
        .expect("execution");
    assert_eq!(
        execution.transition.execution_state,
        crate::task_board::TaskBoardExecutionState::Preparing
    );
    assert_eq!(
        execution.ownership.resources.get("admission_owner"),
        Some(&super::workflow_dispatch::workflow_owner(
            "execution-remote"
        ))
    );
}

#[tokio::test]
async fn status_rejects_a_late_request_after_the_exact_lease_generation_changes() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let accepted = claim_controller(&fixture, &accepted).await;
    let stale_request = status_request(&fixture.request, &accepted);
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("initial lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewal_response = RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: "2026-07-19T10:01:30Z".into(),
        },
    };
    fixture
        .db
        .claim_task_board_remote_renew_io_authority(&renewal, HOST, "2026-07-19T10:00:20Z")
        .await
        .expect("claim renewal authority")
        .expect("renewal remains active");
    let renewed = match fixture
        .db
        .record_task_board_remote_assignment_lease_renewal(
            &renewal,
            &renewal_response,
            HOST,
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("record assignment lease renewal")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected renewed assignment, got {other:?}"),
    };

    assert_ne!(renewed.lease_id, accepted.lease_id);
    assert!(
        !fixture
            .db
            .claim_task_board_remote_status_io_authority(&stale_request, HOST)
            .await
            .expect("reject stale status generation before I/O")
    );
    let current_request = status_request(&fixture.request, &renewed);
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&current_request, HOST)
            .await
            .expect("claim current status generation")
    );
    let mut wrong_expiry = claimed_status(&current_request, &renewed, "2026-07-19T10:00:31Z");
    wrong_expiry
        .lease
        .as_mut()
        .expect("status lease")
        .expires_at = "2026-07-19T10:01:31Z".into();
    let wrong_expiry = wrong_expiry.seal().expect("reseal wrong lease expiry");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(
                &current_request,
                &wrong_expiry,
                HOST,
            )
            .await
            .expect("reject changed expiry for the same lease id"),
        TaskBoardRemoteMutationOutcome::Stale(record) if record.status_response.is_none()
    ));
    let current_status = claimed_status(&current_request, &renewed, "2026-07-19T10:00:32Z");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(
                &current_request,
                &current_status,
                HOST,
            )
            .await
            .expect("record current status generation"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.lease_id == renewed.lease_id && record.status_response.is_some()
    ));
}

#[tokio::test]
async fn executor_rejects_a_rotation_that_does_not_extend_the_current_lease() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    fixture
        .db
        .claim_task_board_remote_assignment(
            &claim_request(&fixture.request, &accepted),
            PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim assignment");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("initial lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        extend_seconds: 20,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal short renewal");

    assert!(matches!(
        fixture
            .db
            .renew_task_board_remote_assignment_lease(
                &renewal,
                PRINCIPAL,
                "2026-07-19T10:00:30Z",
            )
            .await
            .expect("reject short renewal"),
        TaskBoardRemoteMutationOutcome::Stale(record)
            if record.lease_id == accepted.lease_id
                && record.lease_expires_at == accepted.lease_expires_at
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

#[tokio::test]
async fn controller_persists_claim_before_renewal_without_status_polling() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    assert_eq!(claimed.state, TaskBoardRemoteAssignmentState::Claimed);
    assert_eq!(claimed.claimed_at.as_deref(), Some(CLAIMED_AT));
    assert_eq!(
        claimed.last_mutation_kind.as_deref(),
        Some("claim_response")
    );
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: "lease-l1".into(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewal_response = RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: "2026-07-19T10:02:00Z".into(),
        },
    };
    fixture
        .db
        .claim_task_board_remote_renew_io_authority(&renewal, HOST, "2026-07-19T10:00:20Z")
        .await
        .expect("claim remote renewal authority")
        .expect("renewal remains active");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_lease_renewal(
                &renewal,
                &renewal_response,
                HOST,
                "2026-07-19T10:00:30Z",
            )
            .await
            .expect("persist renewal after claim without status"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Claimed
                && record.lease_id.as_deref() == Some("lease-l2")
                && record.last_mutation_kind.as_deref() == Some("renew_response")
    ));
}

pub(crate) async fn accept_controller(
    fixture: &ControllerFixture,
) -> super::TaskBoardRemoteAssignmentRecord {
    let _ = offer_controller(fixture).await;
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim offer I/O authority")
        .expect("offer remains active");
    let response = RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: LEASE_EXPIRES.into(),
        }),
        rejection_code: None,
    };
    match fixture
        .db
        .record_task_board_remote_offer_response(&response, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("record accepted offer")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected accepted offer, got {other:?}"),
    }
}

pub(crate) async fn claim_controller(
    fixture: &ControllerFixture,
    accepted: &super::TaskBoardRemoteAssignmentRecord,
) -> super::TaskBoardRemoteAssignmentRecord {
    let request = claim_request(&fixture.request, accepted);
    let response = RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: LEASE_EXPIRES.into(),
        },
        claimed_at: CLAIMED_AT.into(),
    };
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&request, HOST, "2026-07-19T10:00:05Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    match fixture
        .db
        .record_task_board_remote_assignment_claim(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("persist controller claim")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected claimed assignment, got {other:?}"),
    }
}

pub(crate) fn status_request(
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("assignment lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status request")
}

fn claimed_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    observed_at: &str,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Claimed,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: assignment.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: None,
        workspace_ref: None,
        error_code: None,
        failure_class: None,
        observed_at: observed_at.into(),
    }
    .seal()
    .expect("seal claimed status")
}

pub(crate) fn running_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Running,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: assignment.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some(STARTED_AT.into()),
        workspace_ref: Some("workspace-1".into()),
        error_code: None,
        failure_class: None,
        observed_at: "2026-07-19T10:00:21Z".into(),
    }
    .seal()
    .expect("seal running status")
}
