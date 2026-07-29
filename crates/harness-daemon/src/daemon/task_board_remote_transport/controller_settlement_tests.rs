use sqlx::query;

use super::controller::RemoteExecutionControllerClient;
use super::controller_prepared_test_support::{
    PreparedLifecycle, claim_request, completed_status, persist_claim, prepared_acceptance,
    status_request,
};
use super::controller_tests::{
    HOST_ID, ScriptedResponse, TOKEN_ENV, pinned_client, request_body, spawn_scripted_https_server,
    test_tls_material,
};
use super::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, RemoteSettledResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

#[tokio::test]
async fn lost_settlement_response_restarts_with_one_exact_authority_and_receipt() {
    let state = settlement_ready_controller("settlement-lost-response").await;
    let (request, response) = settlement(&state).await;
    let tls = test_tls_material();
    let (failed_endpoint, failed_requests) =
        spawn_scripted_https_server(&tls, vec![ScriptedResponse::Drop, ScriptedResponse::Drop])
            .await;
    let first = RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(&failed_endpoint, &tls),
        [state.times.after_expiry.clone()],
    );
    temp_env::async_with_vars([(TOKEN_ENV, Some("controller-secret"))], async {
        first
            .settle(&state.prepared.db, &request)
            .await
            .expect_err("lost settlement response remains ambiguous");
    })
    .await;
    let failed_requests = failed_requests.await.expect("failed settlement server");
    assert_eq!(failed_requests.len(), 2);
    assert_eq!(
        request_body(&failed_requests[0]),
        request_body(&failed_requests[1])
    );
    let sealed_body = request_body(&failed_requests[0]).to_vec();
    assert_pending_authority(&state, &request).await;

    let (replay_endpoint, replay_requests) = spawn_scripted_https_server(
        &tls,
        vec![ScriptedResponse::Json(
            serde_json::to_string(&response).expect("settlement response JSON"),
        )],
    )
    .await;
    let restarted = RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(&replay_endpoint, &tls),
        [state.times.after_expiry.clone()],
    );
    let adopted = temp_env::async_with_vars(
        [(TOKEN_ENV, Some("controller-secret"))],
        restarted.settle(&state.prepared.db, &request),
    )
    .await
    .expect("executor receipt replay is adopted after restart");
    assert_eq!(adopted, response);
    let replay_requests = replay_requests.await.expect("replay server");
    assert_eq!(replay_requests.len(), 1);
    assert_eq!(request_body(&replay_requests[0]), sealed_body.as_slice());
    assert_adopted_receipt(&state, &request, &response).await;
    let mut conflicting_response = response.clone();
    conflicting_response.settled_at = state.times.l2_expires_at.clone();
    let response_error = state
        .prepared
        .db
        .record_task_board_remote_settlement_response(&request, &conflicting_response, HOST_ID)
        .await
        .expect_err("immutable settlement response must not change");
    assert!(response_error.to_string().contains("immutable receipt"));

    let (probe_endpoint, probe_requests) = spawn_scripted_https_server(&tls, Vec::new()).await;
    let replayed = RemoteExecutionControllerClient::new_for_tests(
        HOST_ID,
        pinned_client(&probe_endpoint, &tls),
    )
    .settle(&state.prepared.db, &request)
    .await
    .expect("controller receipt replays without network");
    assert_eq!(replayed, response);
    assert!(probe_requests.await.expect("settlement probe").is_empty());
}

#[tokio::test]
async fn settlement_authority_rejects_stale_generation_lease_principal_and_request() {
    let state = settlement_ready_controller("settlement-authority-conflicts").await;
    let (request, _) = settlement(&state).await;
    assert!(
        state
            .prepared
            .db
            .claim_task_board_remote_settlement_io_authority(
                &request,
                HOST_ID,
                &state.times.after_expiry,
            )
            .await
            .expect("claim exact settlement authority")
            .is_none()
    );

    let mut stale_lease = request.clone();
    stale_lease.lease_id = "lease-stale".into();
    assert_conflict(
        &state,
        stale_lease.seal().expect("seal stale lease"),
        HOST_ID,
    )
    .await;
    let mut stale_generation = request.clone();
    stale_generation.binding.fencing_epoch += 1;
    assert_conflict(
        &state,
        stale_generation.seal().expect("seal stale generation"),
        HOST_ID,
    )
    .await;
    let mut stale_result = request.clone();
    stale_result.result_sha256 = Some("f".repeat(64));
    assert_conflict(
        &state,
        stale_result.seal().expect("seal stale result"),
        HOST_ID,
    )
    .await;
    assert_conflict(&state, request.clone(), "different-principal").await;
    assert_pending_authority(&state, &request).await;
}

#[tokio::test]
async fn settlement_authority_rejects_a_missing_controller_handoff() {
    let state = settlement_ready_controller("settlement-missing-handoff").await;
    let (request, _) = settlement(&state).await;
    query(
        "UPDATE task_board_remote_assignments SET
         controller_handoff_kind = NULL,
         controller_handoff_execution_sha256 = NULL,
         controller_handoff_successor_assignment_id = NULL,
         controller_handoff_successor_fencing_epoch = NULL,
         controller_handoff_at = NULL
         WHERE assignment_id = ?1",
    )
    .bind(&request.binding.assignment_id)
    .execute(state.prepared.db.pool())
    .await
    .expect("clear settlement handoff fixture");

    let error = state
        .prepared
        .db
        .claim_task_board_remote_settlement_io_authority(
            &request,
            HOST_ID,
            &state.times.after_expiry,
        )
        .await
        .expect_err("settlement without a controller handoff must fail closed");
    assert!(error.to_string().contains("durable controller handoff"));
    assert_pending_authority_absent(&state, &request).await;
}

pub(super) async fn settlement_ready_controller(item_id: &str) -> PreparedLifecycle {
    let state = prepared_acceptance(item_id).await;
    persist_claim(&state).await;
    let mut status = completed_status(&state);
    status.state = RemoteAssignmentWireState::Unknown;
    status.result = None;
    status.output_artifacts = Default::default();
    status.error_code = Some("remote_assignment_outcome_unknown".into());
    status.status_sha256.clear();
    let status = status.seal().expect("seal evidence-only terminal status");
    state
        .prepared
        .db
        .record_task_board_remote_assignment_status(&status_request(&state), &status, HOST_ID)
        .await
        .expect("persist evidence-only terminal controller status");
    // The recorded Unknown status alone leaves the assignment without the
    // evidence-only controller handoff that settlement authority requires, so
    // settle() would fail before any HTTP request and the scripted servers would
    // wait forever on zero requests. Drive the real recovery path to produce that
    // handoff, exactly as production does after an executor reports an unknown
    // outcome past its lease.
    let recovered = state
        .prepared
        .db
        .recover_task_board_remote_assignments(&state.times.after_expiry)
        .await
        .expect("recover evidence-only settlement authority");
    assert_eq!(
        recovered.recovered.len(),
        1,
        "unknown terminal status must recover into exactly one evidence-only \
         settlement authority: {recovered:?}"
    );
    state
}

pub(super) async fn settlement(
    state: &PreparedLifecycle,
) -> (RemoteSettledRequest, RemoteSettledResponse) {
    let _assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load settlement-ready assignment")
        .expect("settlement-ready assignment");
    let request = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Unknown,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal settlement request");
    let response = RemoteSettledResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        settlement_request_sha256: request.request_sha256.clone(),
        settled_at: state.times.after_expiry.clone(),
    };
    response
        .validate(&request)
        .expect("valid settlement response");
    (request, response)
}

async fn assert_pending_authority(state: &PreparedLifecycle, request: &RemoteSettledRequest) {
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load settlement authority")
        .expect("settlement assignment");
    assert_eq!(assignment.last_mutation_kind.as_deref(), Some("settle"));
    assert_eq!(
        assignment.last_mutation_sha256.as_deref(),
        Some(request.request_sha256.as_str())
    );
}

async fn assert_pending_authority_absent(
    state: &PreparedLifecycle,
    request: &RemoteSettledRequest,
) {
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load rejected settlement authority")
        .expect("settlement assignment");
    // The rejected settle must not claim authority; the assignment keeps the prior claim mutation.
    assert_eq!(
        assignment.last_mutation_kind.as_deref(),
        Some("claim_response")
    );
    assert_eq!(
        assignment.last_mutation_sha256.as_deref(),
        Some(claim_request(state).request_sha256.as_str())
    );
    assert!(assignment.controller_operation.is_none());
}

async fn assert_adopted_receipt(
    state: &PreparedLifecycle,
    request: &RemoteSettledRequest,
    response: &RemoteSettledResponse,
) {
    let receipt = state
        .prepared
        .db
        .task_board_remote_settlement_receipt(&request.binding.assignment_id)
        .await
        .expect("load controller settlement receipt")
        .expect("controller settlement receipt");
    assert!(receipt.is_exact_replay(request, HOST_ID));
    assert_eq!(receipt.response, *response);
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&request.binding.assignment_id)
        .await
        .expect("load settled assignment")
        .expect("settled assignment");
    assert_eq!(assignment.last_mutation_kind, None);
    assert_eq!(assignment.last_mutation_sha256, None);
}

async fn assert_conflict(
    state: &PreparedLifecycle,
    request: RemoteSettledRequest,
    principal: &str,
) {
    let error = state
        .prepared
        .db
        .claim_task_board_remote_settlement_io_authority(
            &request,
            principal,
            &state.times.after_expiry,
        )
        .await
        .expect_err("conflicting settlement must fail closed");
    assert!(error.to_string().contains("settlement"));
}
