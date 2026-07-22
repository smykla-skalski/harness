use super::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse,
    RemoteLease, RemoteStatusResponse, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use super::wire_tests::offer_request;

#[test]
fn cancel_response_preserves_each_truthful_run_stage() {
    let offer = offer_request().seal().expect("seal offer");
    let request = cancel_request(&offer);
    for (claimed_at, started_at, workspace_ref) in [
        (None, None, None),
        (Some("2026-07-19T12:00:30Z"), None, None),
        (
            Some("2026-07-19T12:00:30Z"),
            Some("2026-07-19T12:01:00Z"),
            Some("workspace-assignment-1"),
        ),
    ] {
        let response = cancel_response(
            &request,
            claimed_at.map(str::to_owned),
            started_at.map(str::to_owned),
            workspace_ref.map(str::to_owned),
        );
        response.validate(&request).expect("truthful cancel stage");
        let restored: RemoteCancelResponse = serde_json::from_slice(
            &serde_json::to_vec(&response).expect("serialize cancel response"),
        )
        .expect("restore cancel response");
        assert_eq!(restored, response);
    }
}

#[test]
fn cancel_response_rejects_partial_or_time_reversed_run_evidence() {
    let offer = offer_request().seal().expect("seal offer");
    let request = cancel_request(&offer);
    for (claimed_at, started_at, workspace_ref) in [
        (None, Some("2026-07-19T12:01:00Z"), None),
        (None, None, Some("workspace-assignment-1")),
        (
            Some("2026-07-19T12:00:30Z"),
            None,
            Some("workspace-assignment-1"),
        ),
        (
            Some("2026-07-19T12:00:30Z"),
            Some("2026-07-19T12:01:00Z"),
            None,
        ),
    ] {
        let response = cancel_response(
            &request,
            claimed_at.map(str::to_owned),
            started_at.map(str::to_owned),
            workspace_ref.map(str::to_owned),
        );
        assert_eq!(
            response
                .validate(&request)
                .expect_err("partial cancel evidence denied"),
            RemoteWireError::ResultBindingMismatch
        );
    }

    let mut reversed = cancel_response(
        &request,
        Some("2026-07-19T12:01:30Z".into()),
        Some("2026-07-19T12:01:00Z".into()),
        Some("workspace-assignment-1".into()),
    );
    reversed = reversed.seal(&request).expect("reseal reversed response");
    assert_eq!(
        reversed
            .validate(&request)
            .expect_err("reversed cancel evidence denied"),
        RemoteWireError::ResultBindingMismatch
    );
}

#[test]
fn cancel_response_digest_binds_run_evidence_and_exact_request() {
    let offer = offer_request().seal().expect("seal offer");
    let request = cancel_request(&offer);
    let response = cancel_response(
        &request,
        Some("2026-07-19T12:00:30Z".into()),
        Some("2026-07-19T12:01:00Z".into()),
        Some("workspace-assignment-1".into()),
    );
    let mut tampered = response.clone();
    tampered.workspace_ref = Some("workspace-assignment-2".into());
    assert_eq!(
        tampered
            .validate(&request)
            .expect_err("cancel evidence tampering denied"),
        RemoteWireError::DigestMismatch("cancel_response_sha256")
    );

    let mut other_request = request.clone();
    other_request.reason = "different cancellation".into();
    other_request = other_request.seal().expect("seal other cancel request");
    assert_eq!(
        response
            .validate(&other_request)
            .expect_err("cancel response replay across requests denied"),
        RemoteWireError::DigestMismatch("cancel_response_sha256")
    );
}

#[test]
fn cancelled_status_confirms_every_cancel_request_field() {
    let offer = offer_request().seal().expect("seal offer");
    let request = cancel_request(&offer);
    let response = cancelled_status(&request);
    assert!(response.confirms_cancel(&request));

    let mut other_reason = request.clone();
    other_reason.reason = "different cancellation".into();
    let other_reason = other_reason.seal().expect("seal other reason");
    assert!(!response.confirms_cancel(&other_reason));

    let mut other_lease = request.clone();
    other_lease.lease_id = "lease-2".into();
    let other_lease = other_lease.seal().expect("seal other lease");
    assert!(!response.confirms_cancel(&other_lease));
}

fn cancel_request(offer: &super::wire::RemoteOfferRequest) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-1".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancellation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel")
}

fn cancel_response(
    request: &RemoteCancelRequest,
    claimed_at: Option<String>,
    started_at: Option<String>,
    workspace_ref: Option<String>,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at,
        started_at,
        workspace_ref,
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal(request)
    .expect("seal cancel response")
}

fn cancelled_status(request: &RemoteCancelRequest) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Cancelled,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: "2026-07-19T12:05:00Z".into(),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        error_code: Some(request.reason.clone()),
        failure_class: None,
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal()
    .expect("seal cancelled status")
}
