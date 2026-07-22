use super::*;
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::daemon::task_board_remote_transport::routes_cleanup::CLEANUP_OBSERVATION_PATH;
use crate::daemon::task_board_remote_transport::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};

#[tokio::test]
async fn cleanup_observation_is_pending_then_byte_exact_across_restart() {
    let state = remote_executor_state().await;
    let db = state.async_db.get().expect("async db").clone();
    let (base_url, server) = serve(state.clone()).await;
    let client = Client::new();
    let offer = offer_request("assignment-route-cleanup", "cleanup-route-key");
    let settlement = settle_cancelled_cleanup_route(&client, &base_url, &offer).await;
    let observation = RemoteCleanupObservationRequest::for_settlement(&settlement)
        .expect("seal cleanup observation");

    let pending = authenticated_post(
        &client,
        &base_url,
        CLEANUP_OBSERVATION_PATH,
        HOST_ID,
        &observation,
    )
    .await;
    assert_eq!(pending.status(), StatusCode::SERVICE_UNAVAILABLE);
    let denied = authenticated_post(
        &client,
        &base_url,
        CLEANUP_OBSERVATION_PATH,
        OPERATOR,
        &observation,
    )
    .await;
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);

    let completed_at = (Utc::now() + Duration::seconds(1))
        .to_rfc3339_opts(SecondsFormat::AutoSi, true);
    assert!(matches!(
        db.complete_task_board_remote_assignment_cleanup(
            &settlement,
            HOST_ID,
            &completed_at,
        )
        .await
        .expect("persist exact executor cleanup"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let first = authenticated_post(
        &client,
        &base_url,
        CLEANUP_OBSERVATION_PATH,
        HOST_ID,
        &observation,
    )
    .await
    .bytes()
    .await
    .expect("read first cleanup observation");
    let response = serde_json::from_slice::<RemoteCleanupObservationResponse>(&first)
        .expect("decode cleanup observation");
    response
        .validate(&observation)
        .expect("validate cleanup observation");
    assert_eq!(response.cleanup_completed_at, completed_at);

    server.abort();
    let _ = server.await;
    let (base_url, restarted) = serve(state).await;
    let replay = authenticated_post(
        &client,
        &base_url,
        CLEANUP_OBSERVATION_PATH,
        HOST_ID,
        &observation,
    )
    .await
    .bytes()
    .await
    .expect("read restarted cleanup observation");
    assert_eq!(replay, first);

    let mut wrong_epoch = observation.clone();
    wrong_epoch.binding.fencing_epoch += 1;
    wrong_epoch.request_sha256.clear();
    let wrong_epoch = wrong_epoch.seal().expect("seal wrong cleanup generation");
    let stale = authenticated_post(
        &client,
        &base_url,
        CLEANUP_OBSERVATION_PATH,
        HOST_ID,
        &wrong_epoch,
    )
    .await;
    assert_eq!(stale.status(), StatusCode::CONFLICT);

    restarted.abort();
    let _ = restarted.await;
}

async fn settle_cancelled_cleanup_route(
    client: &Client,
    base_url: &str,
    offer: &RemoteOfferRequest,
) -> RemoteSettledRequest {
    let accepted = authenticated_post(client, base_url, OFFER_PATH, HOST_ID, offer)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode cleanup offer");
    let lease = accepted.lease.expect("cleanup lease");
    let claim = claim_request(offer, &lease.lease_id);
    let claimed = authenticated_post(client, base_url, CLAIM_PATH, HOST_ID, &claim).await;
    assert_eq!(claimed.status(), StatusCode::OK);
    let cancel = cancel_request(offer, &lease.lease_id);
    let cancelled = authenticated_post(client, base_url, CANCEL_PATH, HOST_ID, &cancel)
        .await
        .json::<RemoteCancelResponse>()
        .await
        .expect("decode cleanup cancellation");
    assert_eq!(cancelled.state, RemoteAssignmentWireState::Cancelled);
    let settlement = settlement_request(offer, &lease.lease_id);
    let settled = authenticated_post(client, base_url, SETTLED_PATH, HOST_ID, &settlement)
        .await
        .json::<RemoteSettledResponse>()
        .await
        .expect("decode cleanup settlement");
    settled.validate(&settlement).expect("validate settlement");
    settlement
}

fn claim_request(offer: &RemoteOfferRequest, lease_id: &str) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cleanup claim")
}

fn cancel_request(offer: &RemoteOfferRequest, lease_id: &str) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "cleanup route test".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cleanup cancellation")
}

fn settlement_request(offer: &RemoteOfferRequest, lease_id: &str) -> RemoteSettledRequest {
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.into(),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cleanup settlement")
}
