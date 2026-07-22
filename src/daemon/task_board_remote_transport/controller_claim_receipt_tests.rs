use tokio::net::TcpListener;

use super::controller::RemoteExecutionControllerClient;
use super::controller_tests::{pinned_client, test_tls_material};
use super::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLease, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
    RemoteOfferDisposition, RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_EXECUTOR_PRINCIPAL, RemoteControllerFixture,
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
    accept_remote_executor, remote_controller_fixture, remote_executor_claim_request,
    remote_executor_fixture,
};
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

const HOST: &str = "executor-a";
const CLAIMED_AT: &str = "2026-07-19T10:00:10Z";
const INITIAL_EXPIRY: &str = "2026-07-19T10:01:00Z";
const RENEWED_EXPIRY: &str = "2026-07-19T10:01:30Z";

#[tokio::test]
async fn executor_claim_receipt_survives_renewal_terminalization_and_restart() {
    let fixture = remote_executor_fixture(1).await;
    let accepted = accept_remote_executor(&fixture, &fixture.request).await;
    let claim = remote_executor_claim_request(&fixture.request, &accepted);
    let claimed = match fixture
        .db
        .claim_task_board_remote_assignment(&claim, REMOTE_EXECUTOR_PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim executor assignment")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected claimed executor assignment, got {other:?}"),
    };
    let original = claimed
        .claim_receipt
        .as_ref()
        .expect("immutable claim receipt")
        .response
        .clone();
    let original_json = serde_json::to_vec(&original).expect("serialize original claim response");
    assert_original_claim(&original, &claim);

    let renewal = renewal_request(&fixture.request, &accepted);
    let renewed = match fixture
        .db
        .renew_task_board_remote_assignment_lease(
            &renewal,
            REMOTE_EXECUTOR_PRINCIPAL,
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("renew executor lease")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected renewed executor assignment, got {other:?}"),
    };
    assert_ne!(renewed.lease_id, accepted.lease_id);
    assert_exact_executor_replay(&fixture.db, &claim, &original_json).await;

    let cancel = cancel_request(
        &fixture.request.binding,
        renewed.lease_id.as_deref().expect("renewed lease"),
        &fixture.request.request_sha256,
    );
    assert!(matches!(
        fixture
            .db
            .cancel_task_board_remote_assignment(
                &cancel,
                REMOTE_EXECUTOR_PRINCIPAL,
                "2026-07-19T10:00:40Z",
            )
            .await
            .expect("terminalize executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.wire_state() == RemoteAssignmentWireState::Cancelled
    ));
    assert_exact_executor_replay(&fixture.db, &claim, &original_json).await;

    let database_path = fixture._temp.path().join("executor.db");
    drop(fixture.db);
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("restart executor database");
    assert_exact_executor_replay(&restarted, &claim, &original_json).await;
    assert_claim_replay_rejects_conflicting_evidence(&restarted, &claim).await;
}

#[tokio::test]
async fn controller_claim_receipt_replays_without_network_after_renewal_and_terminalization() {
    let fixture = remote_controller_fixture(1).await;
    let accepted = accept_controller_offer(&fixture).await;
    let claim = controller_claim_request(&fixture, &accepted);
    let original = controller_claim_response(&fixture, &claim);
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&claim, HOST, "2026-07-19T10:00:05Z")
        .await
        .expect("claim controller claim authority")
        .expect("claim remains active");
    fixture
        .db
        .record_task_board_remote_assignment_claim(&claim, &original, HOST, "2026-07-19T10:00:11Z")
        .await
        .expect("record controller claim response");

    let renewed = renew_controller_assignment(&fixture, &accepted).await;
    assert_controller_replay_without_network(&fixture.db, &claim, &original).await;

    let cancel = cancel_request(
        &fixture.request.binding,
        renewed
            .lease_id
            .as_deref()
            .expect("renewed controller lease"),
        &fixture.request.request_sha256,
    );
    let response = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        observed_at: "2026-07-19T10:00:40Z".into(),
    }
    .seal(&cancel)
    .expect("seal controller cancellation response");
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&cancel, HOST, "2026-07-19T10:00:35Z")
        .await
        .expect("claim controller cancellation authority")
        .expect("cancellation remains active");
    fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &cancel,
            &response,
            HOST,
            "2026-07-19T10:00:40Z",
        )
        .await
        .expect("record controller terminal response");
    assert_controller_replay_without_network(&fixture.db, &claim, &original).await;
}

async fn assert_exact_executor_replay(
    db: &AsyncDaemonDb,
    claim: &RemoteClaimRequest,
    original_json: &[u8],
) {
    let sequence = db.current_change_sequence().await.expect("change sequence");
    assert!(matches!(
        db.claim_task_board_remote_assignment(
            claim,
            REMOTE_EXECUTOR_PRINCIPAL,
            "2026-07-19T11:00:00Z",
        )
        .await
        .expect("replay executor claim after lifecycle mutation"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    let (response, record) = db
        .exact_task_board_remote_claim_receipt(claim, REMOTE_EXECUTOR_PRINCIPAL)
        .await
        .expect("load exact immutable claim receipt")
        .expect("claim receipt exists");
    assert_eq!(
        serde_json::to_vec(&response).expect("serialize replayed claim response"),
        original_json
    );
    assert_original_claim(&response, claim);
    assert_eq!(
        record
            .claim_receipt
            .as_ref()
            .expect("durable claim receipt")
            .response,
        response
    );
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
}

fn assert_original_claim(response: &RemoteClaimResponse, claim: &RemoteClaimRequest) {
    assert_eq!(response.claimed_at, CLAIMED_AT);
    assert_eq!(response.lease.lease_id, claim.lease_id);
    assert_eq!(response.lease.expires_at, INITIAL_EXPIRY);
}

async fn assert_claim_replay_rejects_conflicting_evidence(
    db: &AsyncDaemonDb,
    claim: &RemoteClaimRequest,
) {
    assert!(matches!(
        db.claim_task_board_remote_assignment(claim, "other-controller", CLAIMED_AT)
            .await
            .expect("reject wrong-principal claim replay"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(
        db.exact_task_board_remote_claim_receipt(claim, "other-controller")
            .await
            .expect_err("wrong principal must fail closed")
            .to_string()
            .contains("conflicts with replay")
    );

    let mut wrong_request = claim.clone();
    wrong_request.lease_id = "lease-other".into();
    wrong_request.request_sha256.clear();
    let wrong_request = wrong_request.seal().expect("seal wrong claim request");
    assert!(matches!(
        db.claim_task_board_remote_assignment(
            &wrong_request,
            REMOTE_EXECUTOR_PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("reject wrong-request claim replay"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(
        db.exact_task_board_remote_claim_receipt(&wrong_request, REMOTE_EXECUTOR_PRINCIPAL)
            .await
            .expect_err("wrong request must fail closed")
            .to_string()
            .contains("conflicts with replay")
    );

    let mut wrong_generation = claim.clone();
    wrong_generation.binding.fencing_epoch += 1;
    wrong_generation.request_sha256.clear();
    let wrong_generation = wrong_generation
        .seal()
        .expect("seal wrong-generation claim request");
    assert!(matches!(
        db.claim_task_board_remote_assignment(
            &wrong_generation,
            REMOTE_EXECUTOR_PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("reject wrong-generation claim replay"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(
        db.exact_task_board_remote_claim_receipt(&wrong_generation, REMOTE_EXECUTOR_PRINCIPAL)
            .await
            .expect_err("wrong generation must fail closed")
            .to_string()
            .contains("conflicts with replay")
    );
}

fn renewal_request(
    offer: &super::wire::RemoteOfferRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> RemoteLeaseRenewRequest {
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("initial lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal request")
}

fn cancel_request(
    binding: &super::wire::RemoteAttemptBinding,
    lease_id: &str,
    offer_request_sha256: &str,
) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: offer_request_sha256.into(),
        reason: "operator_cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancellation request")
}

async fn accept_controller_offer(
    fixture: &RemoteControllerFixture,
) -> TaskBoardRemoteAssignmentRecord {
    assert!(matches!(
        fixture
            .db
            .offer_task_board_remote_assignment(
                &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                &fixture.request,
                HOST,
                "2026-07-19T10:00:00Z",
                INITIAL_EXPIRY,
                &fixture.request.deadline_at,
            )
            .await
            .expect("persist controller offer"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim controller offer authority")
        .expect("offer remains active");
    let response = RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: INITIAL_EXPIRY.into(),
        }),
        rejection_code: None,
    };
    match fixture
        .db
        .record_task_board_remote_offer_response(&response, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("record accepted controller offer")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected accepted controller offer, got {other:?}"),
    }
}

fn controller_claim_request(
    fixture: &RemoteControllerFixture,
    accepted: &TaskBoardRemoteAssignmentRecord,
) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal controller claim request")
}

fn controller_claim_response(
    fixture: &RemoteControllerFixture,
    claim: &RemoteClaimRequest,
) -> RemoteClaimResponse {
    RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: claim.lease_id.clone(),
            expires_at: INITIAL_EXPIRY.into(),
        },
        claimed_at: CLAIMED_AT.into(),
    }
}

async fn renew_controller_assignment(
    fixture: &RemoteControllerFixture,
    accepted: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardRemoteAssignmentRecord {
    let request = renewal_request(&fixture.request, accepted);
    fixture
        .db
        .claim_task_board_remote_renew_io_authority(&request, HOST, "2026-07-19T10:00:20Z")
        .await
        .expect("claim controller renewal authority")
        .expect("renewal remains active");
    let response = RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: RENEWED_EXPIRY.into(),
        },
    };
    match fixture
        .db
        .record_task_board_remote_assignment_lease_renewal(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("record controller renewal")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected renewed controller assignment, got {other:?}"),
    }
}

async fn assert_controller_replay_without_network(
    db: &AsyncDaemonDb,
    claim: &RemoteClaimRequest,
    original: &RemoteClaimResponse,
) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind network sentinel");
    let endpoint = format!(
        "https://127.0.0.1:{}",
        listener.local_addr().expect("listener address").port()
    );
    let tls = test_tls_material();
    let controller =
        RemoteExecutionControllerClient::new_for_tests(HOST, pinned_client(&endpoint, &tls));
    let network = tokio::spawn(async move { listener.accept().await.is_ok() });

    let (response, outcome) = controller
        .claim(db, claim)
        .await
        .expect("replay controller claim without network");
    assert_eq!(response, *original);
    assert!(matches!(
        outcome,
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    tokio::task::yield_now().await;
    assert!(!network.is_finished(), "claim replay performed network I/O");
    network.abort();
    assert!(
        network
            .await
            .expect_err("network sentinel must be cancelled")
            .is_cancelled()
    );
}
