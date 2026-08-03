use super::*;

#[tokio::test]
async fn executor_lifecycle_replays_renewal_without_accepting_old_generation() {
    let state = remote_executor_state().await;
    let (base_url, server) = serve(state).await;
    let client = Client::new();
    let offer = offer_request("assignment-route-lifecycle", "lifecycle-key");
    let accepted = authenticated_post(&client, &base_url, OFFER_PATH, HOST_ID, &offer)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode offer response");
    let original_acceptance = accepted.clone();
    let old_lease = accepted.lease.expect("accepted lease");

    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: old_lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim");
    let claimed = authenticated_post(&client, &base_url, CLAIM_PATH, HOST_ID, &claim).await;
    assert_eq!(claimed.status(), StatusCode::OK);
    let claimed = claimed
        .json::<RemoteClaimResponse>()
        .await
        .expect("decode claim");
    claimed.validate(&claim).expect("validate claim response");
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    let renew = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: old_lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        extend_seconds: 120,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewed = authenticated_post(&client, &base_url, LEASE_RENEW_PATH, HOST_ID, &renew)
        .await
        .json::<RemoteLeaseRenewResponse>()
        .await
        .expect("decode renewal");
    renewed.validate(&renew).expect("validate renewal response");
    assert_ne!(renewed.lease.lease_id, old_lease.lease_id);

    let replay = authenticated_post(&client, &base_url, LEASE_RENEW_PATH, HOST_ID, &renew)
        .await
        .json::<RemoteLeaseRenewResponse>()
        .await
        .expect("decode renewal replay");
    assert_eq!(replay, renewed);
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    let stale_status = status_request(&offer, &old_lease.lease_id);
    let stale_response =
        authenticated_post(&client, &base_url, STATUS_PATH, HOST_ID, &stale_status).await;
    assert_eq!(stale_response.status(), StatusCode::CONFLICT);

    let current_status = status_request(&offer, &renewed.lease.lease_id);
    let current =
        authenticated_post(&client, &base_url, STATUS_PATH, HOST_ID, &current_status).await;
    assert_eq!(current.status(), StatusCode::OK);
    let current = current
        .json::<RemoteStatusResponse>()
        .await
        .expect("decode status");
    current
        .validate(&current_status)
        .expect("validate exact status generation");
    assert_eq!(current.state, RemoteAssignmentWireState::Claimed);

    exercise_cancel_settle_and_artifact_failure(
        &client,
        &base_url,
        &offer,
        &renewed.lease.lease_id,
    )
    .await;
    assert_offer_replay(&client, &base_url, &offer, &original_acceptance).await;

    server.abort();
    let _ = server.await;
}

async fn assert_offer_replay(
    client: &Client,
    base_url: &str,
    offer: &RemoteOfferRequest,
    expected: &RemoteOfferResponse,
) {
    let replay = authenticated_post(client, base_url, OFFER_PATH, HOST_ID, offer)
        .await
        .json::<RemoteOfferResponse>()
        .await
        .expect("decode immutable offer replay");
    assert_eq!(&replay, expected);
}

async fn exercise_cancel_settle_and_artifact_failure(
    client: &Client,
    base_url: &str,
    offer: &RemoteOfferRequest,
    lease_id: &str,
) {
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel");
    let cancelled = authenticated_post(client, base_url, CANCEL_PATH, HOST_ID, &cancel)
        .await
        .json::<RemoteCancelResponse>()
        .await
        .expect("decode cancellation");
    cancelled.validate(&cancel).expect("validate cancellation");
    assert_eq!(cancelled.state, RemoteAssignmentWireState::Cancelled);

    let settled = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal settlement");
    let settled_bytes = authenticated_post(client, base_url, SETTLED_PATH, HOST_ID, &settled)
        .await
        .bytes()
        .await
        .expect("read settlement response");
    let settled_response =
        serde_json::from_slice::<RemoteSettledResponse>(&settled_bytes).expect("decode settlement");
    settled_response
        .validate(&settled)
        .expect("validate settlement");
    let replay_bytes = authenticated_post(client, base_url, SETTLED_PATH, HOST_ID, &settled)
        .await
        .bytes()
        .await
        .expect("read settlement replay");
    assert_eq!(replay_bytes, settled_bytes);

    let artifact = RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        relative_path: "result/report.json".into(),
        expected_sha256: "e".repeat(64),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact request");
    let unavailable = authenticated_post(client, base_url, ARTIFACT_PATH, HOST_ID, &artifact).await;
    assert_eq!(unavailable.status(), StatusCode::CONFLICT);
}
