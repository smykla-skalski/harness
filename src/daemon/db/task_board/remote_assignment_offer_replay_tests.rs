use super::remote_assignment_test_support::*;
use super::{TaskBoardRemoteOfferOutcome, TaskBoardRemoteOfferReceiptDisposition};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCancelRequest, RemoteLeaseRenewRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

#[tokio::test]
async fn rejected_host_identity_replays_after_operator_settings_restore() {
    let fixture = executor_fixture(1).await;
    replace_executor_host_id(&fixture, "executor-b").await;

    let rejected = match fixture
        .db
        .accept_task_board_remote_assignment_offer(&fixture.request, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("reject offer for replaced executor identity")
    {
        TaskBoardRemoteOfferOutcome::Rejected(record) => record,
        other => panic!("expected durable rejection, got {other:?}"),
    };
    assert_eq!(rejected.request, fixture.request);
    assert_eq!(rejected.authenticated_principal, PRINCIPAL);
    assert_eq!(
        rejected.disposition,
        TaskBoardRemoteOfferReceiptDisposition::Rejected
    );
    assert_eq!(
        rejected.rejection_code.as_deref(),
        Some("executor_unavailable")
    );
    assert_eq!(rejected.initial_lease_id, None);
    assert_eq!(rejected.initial_lease_expires_at, None);
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("load rejected assignment")
            .is_none()
    );

    replace_executor_host_id(&fixture, HOST).await;
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &fixture.request,
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:05Z",
            )
            .await
            .expect("replay rejection after settings restore"),
        TaskBoardRemoteOfferOutcome::Rejected(record) if record == rejected
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
async fn accepted_offer_replay_retains_the_initial_lease_after_renewal_and_terminal_state() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let initial = match fixture
        .db
        .accept_task_board_remote_assignment_offer(
            &fixture.request,
            PRINCIPAL,
            INSTANCE,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("replay initial acceptance")
    {
        TaskBoardRemoteOfferOutcome::AcceptedReplay(receipt) => receipt,
        other => panic!("expected immutable accepted replay, got {other:?}"),
    };
    fixture
        .db
        .claim_task_board_remote_assignment(
            &claim_request(&fixture.request, &accepted),
            PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim accepted offer");
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("initial lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal lease renewal");
    let renewed = match fixture
        .db
        .renew_task_board_remote_assignment_lease(&renewal, PRINCIPAL, "2026-07-19T10:00:30Z")
        .await
        .expect("renew lease")
    {
        super::TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected renewed assignment, got {other:?}"),
    };
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: renewed.lease_id.clone().expect("renewed lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "operator_cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancellation");
    fixture
        .db
        .cancel_task_board_remote_assignment(&cancel, PRINCIPAL, "2026-07-19T10:00:40Z")
        .await
        .expect("cancel assignment");

    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &fixture.request,
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:50Z",
            )
            .await
            .expect("replay accepted response after terminal state"),
        TaskBoardRemoteOfferOutcome::AcceptedReplay(receipt) if receipt == initial
    ));
    assert_eq!(initial.initial_lease_id, accepted.lease_id);
    assert_ne!(initial.initial_lease_id, renewed.lease_id);
}

async fn replace_executor_host_id(fixture: &ExecutorFixture, host_id: &str) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.host_id = host_id.into();
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace executor identity");
}
