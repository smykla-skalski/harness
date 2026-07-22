use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::{
    accept_controller, claim_controller, running_status, status_request,
};
use super::remote_assignment_test_support::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLease, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn lost_renewal_response_replay_converges_before_expiry_without_restarting() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let status_request = status_request(&fixture.request, &claimed);
    fixture
        .db
        .record_task_board_remote_assignment_status(
            &status_request,
            &running_status(&status_request, &claimed),
            HOST,
        )
        .await
        .expect("record durable start evidence");
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
    let response = RemoteLeaseRenewResponse {
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
        .claim_task_board_remote_renew_io_authority(&renewal, HOST, "2026-07-19T10:00:30Z")
        .await
        .expect("claim remote renewal authority")
        .expect("renewal remains active");

    let updated = fixture
        .db
        .record_task_board_remote_assignment_lease_renewal(
            &renewal,
            &response,
            HOST,
            "2026-07-19T10:00:31Z",
        )
        .await
        .expect("reconcile repeated renewal response");
    assert!(matches!(
        updated,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.lease_id.as_deref() == Some("lease-l2")
                && record.started_at.as_deref() == Some(STARTED_AT)
                && record.workspace_ref.as_deref() == Some("workspace-1")
                && record.last_mutation_kind.as_deref() == Some("renew_response")
                && record.status_response.is_none()
    ));
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_lease_renewal(
                &renewal,
                &response,
                HOST,
                "2026-07-19T10:00:31Z",
            )
            .await
            .expect("replay reconciled renewal response"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    let recovered = fixture
        .db
        .recover_task_board_remote_assignments("2026-07-19T10:01:30Z")
        .await
        .expect("recover after old lease expiry");
    assert!(recovered.recovered.is_empty());
    assert!(recovered.failures.is_empty());
    let durable = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load renewed assignment")
        .expect("renewed assignment");
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Running);
    assert_eq!(durable.lease_id.as_deref(), Some("lease-l2"));
    assert_eq!(durable.started_at.as_deref(), Some(STARTED_AT));
}

#[tokio::test]
async fn renew_token_survives_recovery_so_a_late_renewal_response_unstrands() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let status_request = status_request(&fixture.request, &claimed);
    fixture
        .db
        .record_task_board_remote_assignment_status(
            &status_request,
            &running_status(&status_request, &claimed),
            HOST,
        )
        .await
        .expect("record durable start evidence");
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
    let response = RemoteLeaseRenewResponse {
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
        .claim_task_board_remote_renew_io_authority(&renewal, HOST, "2026-07-19T10:00:30Z")
        .await
        .expect("claim remote renewal authority")
        .expect("renewal remains active");

    // The old lease l1 expires (10:01:00Z) while the executor's renewal to l2 is still
    // in flight; recovery must preserve the renew token, not abandon it and strand the
    // live worker to HumanRequired.
    let recovered = fixture
        .db
        .recover_task_board_remote_assignments("2026-07-19T10:01:30Z")
        .await
        .expect("recover with a renewal in flight");
    assert!(recovered.failures.is_empty());
    let after_recovery = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load recovered assignment")
        .expect("recovered assignment");
    assert_eq!(
        after_recovery.state,
        TaskBoardRemoteAssignmentState::Unknown
    );
    assert!(
        after_recovery
            .controller_operation
            .as_ref()
            .is_some_and(|operation| operation.kind == "renew"),
        "recovery must preserve the in-flight renew token, not abandon it"
    );

    // The late renewal response then reconciles the rotated lease instead of going
    // Stale, so the still-live worker is not permanently stranded.
    let updated = fixture
        .db
        .record_task_board_remote_assignment_lease_renewal(
            &renewal,
            &response,
            HOST,
            "2026-07-19T10:01:31Z",
        )
        .await
        .expect("reconcile the late renewal after recovery");
    assert!(matches!(
        updated,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.lease_id.as_deref() == Some("lease-l2")
    ));
    let durable = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load un-stranded assignment")
        .expect("un-stranded assignment");
    assert_eq!(durable.lease_id.as_deref(), Some("lease-l2"));
}
