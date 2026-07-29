use base64::Engine as _;

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactFetchRequest, RemoteArtifactFetchResponse,
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse,
    RemoteClaimRequest, RemoteClaimResponse, RemoteLease, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSettledRequest, RemoteSettledResponse, RemoteStatusRequest, RemoteStatusResponse,
    RemoteTypedResult, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use super::wire_tests::{artifact, offer_request};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardFailureClass, TaskBoardImplementationResult, TaskBoardLocalAttemptResult,
};

#[path = "wire_provenance_offer_digest_tests.rs"]
mod offer_digest_tests;
use offer_digest_tests::{assert_request_offer_digest, assert_response_offer_digest};

#[path = "wire_provenance_status_evidence_tests.rs"]
mod status_evidence_tests;

#[test]
fn fetched_artifact_must_match_requested_path_size_and_digest() {
    let content = b"git bundle bytes";
    let entry = artifact("implementation.bundle", content);
    let offer = offer_request().seal().expect("seal offer");
    let request = artifact_request(&offer, entry.clone());
    assert_request_offer_digest(
        &request,
        RemoteArtifactFetchRequest::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
    let response = RemoteArtifactFetchResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        artifact: entry,
        content_base64: base64::engine::general_purpose::STANDARD.encode(content),
    };
    assert_response_offer_digest(
        &response,
        &request,
        RemoteArtifactFetchResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
    assert_eq!(
        response.validate(&request).expect("artifact response"),
        content
    );

    let mut tampered = response;
    tampered.content_base64 = base64::engine::general_purpose::STANDARD.encode(b"other");
    assert_eq!(
        tampered
            .validate(&request)
            .expect_err("tampered bytes denied"),
        RemoteWireError::DigestMismatch("artifact_sha256")
    );
}

#[test]
fn terminal_status_echoes_the_original_offer_digest() {
    let mut offer = offer_request();
    // The completed result is an implementation artifact, so the attempt binding
    // must name the matching implementation action for the phase.
    offer.binding.action_key = "implementation:1".into();
    let offer = offer.seal().expect("seal offer");
    let request = status_request(&offer);
    assert_request_offer_digest(&request, RemoteStatusRequest::validate, |value, digest| {
        value.offer_request_sha256 = digest;
    });
    let response = RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding,
        state: RemoteAssignmentWireState::Completed,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: None,
        result: Some(
            RemoteTypedResult::seal(
                local_implementation_result("result-head"),
                offer.request_sha256,
            )
            .expect("seal remote result"),
        ),
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some("2026-07-19T12:00:30Z".into()),
        started_at: Some("2026-07-19T12:01:00Z".into()),
        workspace_ref: Some("workspace-assignment-1".into()),
        error_code: None,
        failure_class: None,
        observed_at: "2026-07-19T12:05:00Z".into(),
    }
    .seal()
    .expect("seal status response");
    assert_response_offer_digest(
        &response,
        &request,
        RemoteStatusResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
}

#[test]
fn failed_status_requires_durable_claim_and_run_evidence() {
    let offer = offer_request().seal().expect("seal offer");
    let request = status_request(&offer);
    let response = RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding,
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256,
        status_sha256: String::new(),
        lease: None,
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        error_code: Some("worker_failed".into()),
        failure_class: Some(crate::task_board::TaskBoardFailureClass::Transient),
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal()
    .expect("seal failed status");
    assert_eq!(
        response
            .validate(&request)
            .expect_err("unbound failure denied"),
        RemoteWireError::ResultBindingMismatch
    );
}

#[test]
fn failed_at_claimed_status_without_start_evidence_round_trips() {
    let offer = offer_request().seal().expect("seal offer");
    let request = status_request(&offer);
    let response = RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding,
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256,
        status_sha256: String::new(),
        lease: None,
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some("2026-07-19T12:00:30Z".into()),
        started_at: None,
        workspace_ref: None,
        error_code: Some("CODEX001".into()),
        failure_class: Some(crate::task_board::TaskBoardFailureClass::Transient),
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal()
    .expect("seal failed-at-claimed status");
    response
        .validate(&request)
        .expect("a claimed-but-not-started failure is valid run evidence");
}

#[test]
fn failed_status_binds_every_concrete_failure_class_and_round_trips_strictly() {
    let offer = offer_request().seal().expect("seal offer");
    let request = status_request(&offer);
    for (failure_class, encoded) in [
        (TaskBoardFailureClass::Transient, "transient"),
        (TaskBoardFailureClass::Permanent, "permanent"),
        (TaskBoardFailureClass::Authentication, "authentication"),
        (TaskBoardFailureClass::Configuration, "configuration"),
        (TaskBoardFailureClass::Policy, "policy"),
        (TaskBoardFailureClass::Conflict, "conflict"),
    ] {
        let response = failed_status(&offer, failure_class);
        response.validate(&request).expect("bound failed status");
        let bytes = serde_json::to_vec(&response).expect("serialize failed status");
        let json: serde_json::Value =
            serde_json::from_slice(&bytes).expect("decode failed status value");
        assert_eq!(json["failure_class"], encoded);
        let restored: RemoteStatusResponse =
            serde_json::from_slice(&bytes).expect("restore failed status");
        assert_eq!(restored, response);

        let mut tampered = response;
        tampered.failure_class = Some(if failure_class == TaskBoardFailureClass::Transient {
            TaskBoardFailureClass::Permanent
        } else {
            TaskBoardFailureClass::Transient
        });
        assert_eq!(
            tampered
                .validate(&request)
                .expect_err("failure class digest tampering denied"),
            RemoteWireError::DigestMismatch("status_sha256")
        );
    }
}

#[test]
fn failure_class_is_required_only_for_failed_status() {
    let offer = offer_request().seal().expect("seal offer");
    let request = status_request(&offer);
    let mut missing = failed_status(&offer, TaskBoardFailureClass::Transient);
    missing.failure_class = None;
    missing = missing.seal().expect("reseal missing failure class");
    assert_eq!(
        missing
            .validate(&request)
            .expect_err("missing failure class denied"),
        RemoteWireError::MissingField("failure_class")
    );

    let mut non_failed = failed_status(&offer, TaskBoardFailureClass::Policy);
    non_failed.state = RemoteAssignmentWireState::Cancelled;
    non_failed = non_failed.seal().expect("reseal non-failed status");
    assert_eq!(
        non_failed
            .validate(&request)
            .expect_err("non-failed class denied"),
        RemoteWireError::ResultBindingMismatch
    );

    let unknown_outcome = failed_status(&offer, TaskBoardFailureClass::UnknownOutcome);
    assert_eq!(
        unknown_outcome
            .validate(&request)
            .expect_err("ambiguous outcome cannot claim a failed status"),
        RemoteWireError::ResultBindingMismatch
    );

    let mut json =
        serde_json::to_value(failed_status(&offer, TaskBoardFailureClass::UnknownOutcome))
            .expect("failed status JSON");
    json["failure_class"] = serde_json::Value::String("retry_maybe".into());
    assert!(serde_json::from_value::<RemoteStatusResponse>(json).is_err());
}

#[test]
fn offer_claim_and_renew_echo_exact_original_offer_digest() {
    let offer = offer_request().seal().expect("seal offer");
    let lease = lease();
    let offer_response = RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(lease.clone()),
        rejection_code: None,
    };
    assert_response_offer_digest(
        &offer_response,
        &offer,
        RemoteOfferResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );

    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease.lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim");
    assert_request_offer_digest(&claim, RemoteClaimRequest::validate, |value, digest| {
        value.offer_request_sha256 = digest;
    });
    let claim_response = RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: claim.binding.clone(),
        offer_request_sha256: claim.offer_request_sha256.clone(),
        lease: lease.clone(),
        claimed_at: "2026-07-19T12:01:00Z".into(),
    };
    assert_response_offer_digest(
        &claim_response,
        &claim,
        RemoteClaimResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );

    let renew = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: claim.binding,
        lease_id: lease.lease_id.clone(),
        offer_request_sha256: claim.offer_request_sha256,
        extend_seconds: 30,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    assert_request_offer_digest(
        &renew,
        RemoteLeaseRenewRequest::validate,
        |value, digest| {
            value.offer_request_sha256 = digest;
        },
    );
    let renewal_response = RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: renew.binding.clone(),
        offer_request_sha256: renew.offer_request_sha256.clone(),
        lease,
    };
    assert_response_offer_digest(
        &renewal_response,
        &renew,
        RemoteLeaseRenewResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
}

#[test]
fn status_cancel_settle_and_artifact_fetch_bind_original_offer_digest() {
    let offer = offer_request().seal().expect("seal offer");
    let status = status_request(&offer);
    assert_request_offer_digest(&status, RemoteStatusRequest::validate, |value, digest| {
        value.offer_request_sha256 = digest;
    });

    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-1".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancellation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel");
    assert_request_offer_digest(&cancel, RemoteCancelRequest::validate, |value, digest| {
        value.offer_request_sha256 = digest;
    });
    let cancel_response = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: cancel.binding.clone(),
        offer_request_sha256: cancel.offer_request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal(&cancel)
    .expect("seal cancel response");
    assert_response_offer_digest(
        &cancel_response,
        &cancel,
        RemoteCancelResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );

    let settled = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-1".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal settlement");
    assert_request_offer_digest(&settled, RemoteSettledRequest::validate, |value, digest| {
        value.offer_request_sha256 = digest;
    });
    let settled_response = RemoteSettledResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: settled.binding.clone(),
        offer_request_sha256: settled.offer_request_sha256.clone(),
        settlement_request_sha256: settled.request_sha256.clone(),
        settled_at: "2026-07-19T12:03:00Z".into(),
    };
    assert_response_offer_digest(
        &settled_response,
        &settled,
        RemoteSettledResponse::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
    let mut malformed_settlement = settled_response.clone();
    malformed_settlement
        .settlement_request_sha256
        .make_ascii_uppercase();
    assert!(matches!(
        malformed_settlement.validate(&settled),
        Err(RemoteWireError::InvalidDigest("settlement_request_sha256"))
    ));
    let mut different_settlement = settled_response.clone();
    different_settlement.settlement_request_sha256 = "b".repeat(64);
    assert!(matches!(
        different_settlement.validate(&settled),
        Err(RemoteWireError::DigestMismatch("settlement_request_sha256"))
    ));

    let fetch = artifact_request(&offer, artifact("result.json", b"result"));
    assert_request_offer_digest(
        &fetch,
        RemoteArtifactFetchRequest::validate,
        |value, digest| value.offer_request_sha256 = digest,
    );
}

fn failed_status(
    offer: &RemoteOfferRequest,
    failure_class: TaskBoardFailureClass,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: None,
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some("2026-07-19T12:00:30Z".into()),
        started_at: Some("2026-07-19T12:01:00Z".into()),
        workspace_ref: Some("workspace-assignment-1".into()),
        error_code: Some("worker_failed".into()),
        failure_class: Some(failure_class),
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal()
    .expect("seal failed status")
}

fn status_request(offer: &RemoteOfferRequest) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-1".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status")
}

fn artifact_request(
    offer: &RemoteOfferRequest,
    entry: RemoteArtifactEntry,
) -> RemoteArtifactFetchRequest {
    RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-1".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        relative_path: entry.relative_path,
        expected_sha256: entry.sha256,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact request")
}

fn lease() -> RemoteLease {
    RemoteLease {
        lease_id: "lease-1".into(),
        expires_at: "2026-07-19T12:01:00Z".into(),
    }
}

fn local_implementation_result(head: &str) -> TaskBoardLocalAttemptResult {
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: "execution-1".into(),
        action_key: "implementation:1".into(),
        attempt: 1,
        idempotency_key: "attempt-key".into(),
        exact_head_revision: head.into(),
        artifact: TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: 1,
            base_head_revision: "1111111111111111111111111111111111111111".into(),
            head_revision: head.into(),
            summary: "implemented".into(),
            evidence: Vec::new(),
        }),
    }
}
