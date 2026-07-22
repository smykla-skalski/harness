use chrono::{Duration, SecondsFormat, Utc};

use super::controller_authority_test_support::{
    HOST_ID, TOKEN_ENV, accepted_offer, central_offer, claim_request, claim_response,
    persist_acceptance, pinned_controller, pinned_controller_for_host, spawn_probe_server,
    test_tls_material, try_stop,
};
use super::controller_authority_tests::assert_concurrent_database_error;
use super::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteLease,
    RemoteLeaseRenewRequest, RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteMutationOutcome, utc_now};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn accepted_offer_receipt_replays_original_l1_after_claim_renewal_and_terminal() {
    let state = central_offer().await;
    let original = accepted_offer(&state);
    persist_acceptance(&state).await;
    let claim = claim_request(&state);
    let claimed = claim_response(&state);
    assert!(
        state
            .fixture
            .db
            .claim_task_board_remote_claim_io_authority(&claim, HOST_ID, &utc_now())
            .await
            .expect("claim remote claim authority")
            .is_some()
    );
    state
        .fixture
        .db
        .record_task_board_remote_assignment_claim(&claim, &claimed, HOST_ID, &utc_now())
        .await
        .expect("persist claim response");
    let renewal = renewal_request(&state);
    let renewal_response = renewal_response(&state);
    persist_renewal(&state.fixture.db, &renewal, &renewal_response).await;
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller(&endpoint, &tls);
    let (renewed_replay, terminal_replay) =
        temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
            let renewed = controller
                .offer(&state.fixture.db, &state.fixture.request)
                .await
                .expect("replay original offer after renewal");
            let cancel = cancel_request(&state);
            state
                .fixture
                .db
                .claim_task_board_remote_cancel_io_authority(&cancel, HOST_ID, &utc_now())
                .await
                .expect("claim terminal cancellation authority")
                .expect("terminal cancellation remains active");
            state
                .fixture
                .db
                .record_task_board_remote_assignment_cancel(
                    &cancel,
                    &cancel_response(&state, &claimed.claimed_at),
                    HOST_ID,
                    &utc_now(),
                )
                .await
                .expect("persist terminal cancellation");
            let terminal = controller
                .offer(&state.fixture.db, &state.fixture.request)
                .await
                .expect("replay original offer after terminal mutation");
            (renewed, terminal)
        })
        .await;
    let original_bytes = serde_json::to_vec(&original).expect("original response JSON");
    assert_eq!(
        serde_json::to_vec(&renewed_replay.0).expect("renewed replay JSON"),
        original_bytes
    );
    assert!(matches!(
        renewed_replay.1,
        TaskBoardRemoteMutationOutcome::Replayed(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Claimed
                && record.lease_id.as_deref() == Some("lease-l2")
    ));
    assert_eq!(
        serde_json::to_vec(&terminal_replay.0).expect("terminal replay JSON"),
        original_bytes
    );
    assert!(matches!(
        terminal_replay.1,
        TaskBoardRemoteMutationOutcome::Replayed(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
                && record.lease_id.as_deref() == Some("lease-l2")
    ));
    assert_eq!(requests.await.expect("offer replay probe"), 0);
}

async fn persist_renewal(
    db: &AsyncDaemonDb,
    renewal: &RemoteLeaseRenewRequest,
    response: &RemoteLeaseRenewResponse,
) {
    assert!(
        db.claim_task_board_remote_renew_io_authority(renewal, HOST_ID, &utc_now())
            .await
            .expect("claim lease renewal authority")
            .is_some()
    );
    db.record_task_board_remote_assignment_lease_renewal(renewal, response, HOST_ID, &utc_now())
        .await
        .expect("persist renewal response");
}

#[tokio::test]
async fn rejected_capacity_receipt_replays_after_fallback_and_rejects_conflicts() {
    let state = central_offer().await;
    let response = rejected_offer(&state);
    assert!(state
        .fixture
        .db
        .claim_task_board_remote_offer_io_authority(
            &state.fixture.request,
            HOST_ID,
            &utc_now(),
        )
        .await
        .expect("claim rejected offer authority")
        .is_some());
    state
        .fixture
        .db
        .record_task_board_remote_offer_response(&response, HOST_ID, &utc_now())
        .await
        .expect("persist capacity rejection and local fallback");
    try_stop(&state, "stop after local fallback")
        .await
        .expect("mutate parent after rejected receipt");

    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller(&endpoint, &tls);
    let wrong_principal = pinned_controller_for_host(&endpoint, &tls, "executor-b");
    let mut conflicting = state.fixture.request.clone();
    conflicting.launch.prompt.push_str(" conflicting");
    conflicting = conflicting.seal().expect("reseal conflicting offer");
    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let replay = controller
            .offer(&state.fixture.db, &state.fixture.request)
            .await
            .expect("replay rejected offer from immutable receipt");
        assert_eq!(
            serde_json::to_vec(&replay.0).unwrap(),
            serde_json::to_vec(&response).unwrap()
        );
        assert!(matches!(
            replay.1,
            TaskBoardRemoteMutationOutcome::Replayed(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Superseded
        ));
        assert_concurrent_database_error(
            controller
                .offer(&state.fixture.db, &conflicting)
                .await
                .expect_err("conflicting sealed offer cannot reuse receipt"),
        );
        assert_concurrent_database_error(
            wrong_principal
                .offer(&state.fixture.db, &state.fixture.request)
                .await
                .expect_err("conflicting principal cannot reuse receipt"),
        );
    })
    .await;
    assert_eq!(requests.await.expect("rejected replay probe"), 0);
}

fn renewal_request(
    state: &super::controller_authority_test_support::AuthorityFixture,
) -> RemoteLeaseRenewRequest {
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        lease_id: "lease-l1".into(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        extend_seconds: 600,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal lease renewal")
}

fn renewal_response(
    state: &super::controller_authority_test_support::AuthorityFixture,
) -> RemoteLeaseRenewResponse {
    RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: canonical_time(Utc::now() + Duration::minutes(20)),
        },
    }
}

fn cancel_request(
    state: &super::controller_authority_test_support::AuthorityFixture,
) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        lease_id: "lease-l2".into(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        reason: "terminal replay proof".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancellation")
}

fn cancel_response(
    state: &super::controller_authority_test_support::AuthorityFixture,
    claimed_at: &str,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        // Cancelling a claimed assignment must echo the observed claim evidence.
        claimed_at: Some(claimed_at.into()),
        started_at: None,
        workspace_ref: None,
        observed_at: utc_now(),
    }
    .seal(&cancel_request(state))
    .expect("seal cancellation response")
}

fn rejected_offer(
    state: &super::controller_authority_test_support::AuthorityFixture,
) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.fixture.request.binding.clone(),
        offer_request_sha256: state.fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Rejected,
        lease: None,
        rejection_code: Some("capacity_changed".into()),
    }
}

fn canonical_time(time: chrono::DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Secs, true)
}
