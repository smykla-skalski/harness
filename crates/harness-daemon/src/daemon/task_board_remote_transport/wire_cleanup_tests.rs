use super::*;
use crate::daemon::task_board_remote_transport::wire::TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION;
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

const COMPLETED_AT: &str = "2026-07-20T12:00:00Z";

#[test]
fn cleanup_observation_seals_exact_generation_and_settlement() {
    let request = cleanup_request();
    let response = cleanup_response(&request);
    response
        .validate(&request)
        .expect("validate cleanup response");

    let replay = cleanup_response(&request);
    assert_eq!(replay, response);

    let mut wrong_epoch = request.clone();
    wrong_epoch.binding.fencing_epoch += 1;
    wrong_epoch.request_sha256.clear();
    let wrong_epoch = wrong_epoch.seal().expect("seal wrong epoch request");
    assert!(matches!(
        response.validate(&wrong_epoch),
        Err(RemoteWireError::ResultBindingMismatch)
    ));

    let mut wrong_settlement = request.clone();
    wrong_settlement.settlement_request_sha256 = "d".repeat(64);
    wrong_settlement.request_sha256.clear();
    let wrong_settlement = wrong_settlement
        .seal()
        .expect("seal wrong settlement request");
    assert!(matches!(
        response.validate(&wrong_settlement),
        Err(RemoteWireError::ResultBindingMismatch)
    ));
}

#[test]
fn cleanup_observation_rejects_tamper_and_noncanonical_time() {
    let request = cleanup_request();
    let response = cleanup_response(&request);

    let mut tampered = response.clone();
    tampered.cleanup_completed_at = "2026-07-20T12:00:01Z".into();
    assert!(matches!(
        tampered.validate(&request),
        Err(RemoteWireError::DigestMismatch("response_sha256"))
    ));

    let mut noncanonical = response;
    noncanonical.cleanup_completed_at = "2026-07-20T12:00:00+00:00".into();
    noncanonical.response_sha256.clear();
    let noncanonical = noncanonical
        .seal(&request)
        .expect("seal response before time validation");
    assert!(matches!(
        noncanonical.validate(&request),
        Err(RemoteWireError::InvalidTimestamp("cleanup_completed_at"))
    ));
}

fn cleanup_request() -> RemoteCleanupObservationRequest {
    RemoteCleanupObservationRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: binding(),
        lease_id: "lease-cleanup".into(),
        offer_request_sha256: "a".repeat(64),
        settlement_request_sha256: "b".repeat(64),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cleanup observation request")
}

fn binding() -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        assignment_id: "assignment-cleanup".into(),
        execution_id: "execution-cleanup".into(),
        phase: TaskBoardExecutionPhase::Review,
        workflow_kind: TaskBoardWorkflowKind::Review,
        action_key: "review:codex".into(),
        attempt: 1,
        idempotency_key: "cleanup-key".into(),
        host_id: "executor-a".into(),
        host_instance_id: "instance-a".into(),
        fencing_epoch: 7,
        configuration_revision: 11,
        execution_record_sha256: "e".repeat(64),
        repository: "example/harness".into(),
        base_revision: "1".repeat(40),
        expected_head_revision: Some("2".repeat(40)),
    }
}

fn cleanup_response(request: &RemoteCleanupObservationRequest) -> RemoteCleanupObservationResponse {
    RemoteCleanupObservationResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        settlement_request_sha256: request.settlement_request_sha256.clone(),
        cleanup_completed_at: COMPLETED_AT.into(),
        response_sha256: String::new(),
    }
    .seal(request)
    .expect("seal cleanup observation response")
}
