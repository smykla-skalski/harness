use super::controller::RemoteExecutionControllerClient;
use super::controller_prepared_test_support::{persist_claim, prepared_acceptance, status_request};
use super::controller_tests::{
    HOST_ID, ScriptedResponse, TOKEN_ENV, cancel_request, cancel_response, claimed_cancel_response,
    pinned_client, request_body, spawn_scripted_https_server, test_tls_material,
};
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn lost_cancel_response_retries_exactly_and_restarts_from_durable_response() {
    let state = prepared_acceptance("lost-cancel-response").await;
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let response = cancel_response(&state.prepared.offer, &state.times.before_expiry);
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_scripted_https_server(
        &tls,
        vec![
            ScriptedResponse::Drop,
            ScriptedResponse::Json(serde_json::to_string(&response).expect("cancel response JSON")),
        ],
    )
    .await;
    let controller = RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(&endpoint, &tls),
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    );

    let cancelled = temp_env::async_with_vars([(TOKEN_ENV, Some("controller-secret"))], async {
        controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect("exact cancel retry converges")
    })
    .await;
    assert_eq!(cancelled.0, response);
    assert!(matches!(
        cancelled.1,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
    ));
    let requests = requests.await.expect("scripted TLS server");
    assert_eq!(requests.len(), 2);
    assert_eq!(request_body(&requests[0]), request_body(&requests[1]));

    let restarted =
        RemoteExecutionControllerClient::new_for_tests(HOST_ID, pinned_client(&endpoint, &tls));
    let replayed = restarted
        .cancel(&state.prepared.db, &cancel)
        .await
        .expect("restart replays durable cancellation without I/O");
    assert_eq!(replayed.0, response);
    assert!(matches!(
        replayed.1,
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    let durable = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load controller assignment")
        .expect("controller assignment exists");
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Cancelled);
    assert_eq!(durable.lease_id.as_deref(), Some("lease-admission"));
    assert_eq!(
        durable.cancel_requested_at.as_deref(),
        Some(state.times.before_expiry.as_str())
    );
}

#[tokio::test]
async fn claim_only_cancel_restarts_with_the_exact_empty_response_evidence() {
    let state = prepared_acceptance("claim-only-cancel-replay").await;
    persist_claim(&state).await;
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let response = claimed_cancel_response(
        &state.prepared.offer,
        &state.times.before_expiry,
        &state.times.before_expiry,
    );
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_scripted_https_server(
        &tls,
        vec![ScriptedResponse::Json(
            serde_json::to_string(&response).expect("cancel response JSON"),
        )],
    )
    .await;
    let controller = RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(&endpoint, &tls),
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    );
    let cancelled = temp_env::async_with_vars(
        [(TOKEN_ENV, Some("controller-secret"))],
        controller.cancel(&state.prepared.db, &cancel),
    )
    .await
    .expect("claim-only cancel succeeds");
    assert_eq!(cancelled.0, response);
    let requests = requests.await.expect("scripted TLS server");
    assert_eq!(requests.len(), 1);

    let restarted =
        RemoteExecutionControllerClient::new_for_tests(HOST_ID, pinned_client(&endpoint, &tls));
    let replayed = restarted
        .cancel(&state.prepared.db, &cancel)
        .await
        .expect("restart replays exact empty response evidence");
    assert_eq!(
        serde_json::to_vec(&replayed.0).expect("serialize replayed response"),
        serde_json::to_vec(&response).expect("serialize original response")
    );
    assert!(matches!(
        replayed.1,
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    let durable = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load controller assignment")
        .expect("controller assignment exists");
    assert_eq!(
        durable.claimed_at.as_deref(),
        Some(state.times.before_expiry.as_str())
    );
}

#[tokio::test]
async fn two_lost_cancel_responses_reconcile_from_status_after_restart() {
    let state = prepared_acceptance("lost-cancel-status-reconciliation").await;
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let tls = test_tls_material();
    let (cancel_endpoint, cancel_requests) =
        spawn_scripted_https_server(&tls, vec![ScriptedResponse::Drop, ScriptedResponse::Drop])
            .await;
    let controller = RemoteExecutionControllerClient::new_for_tests_with_times(
        HOST_ID,
        pinned_client(&cancel_endpoint, &tls),
        [state.times.before_expiry.clone()],
    );

    temp_env::async_with_vars([(TOKEN_ENV, Some("controller-secret"))], async {
        controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect_err("both cancel responses are lost");
    })
    .await;
    assert_eq!(
        cancel_requests.await.expect("cancel request count").len(),
        2
    );
    let pending = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load pending cancel")
        .expect("pending cancel assignment");
    assert_eq!(pending.state, TaskBoardRemoteAssignmentState::Offered);
    assert_eq!(pending.error.as_deref(), Some(cancel.reason.as_str()));
    assert_eq!(
        pending
            .controller_operation
            .as_ref()
            .map(|operation| operation.request_sha256.as_str()),
        Some(cancel.request_sha256.as_str())
    );

    let status_request = status_request(&state);
    let status_response = cancelled_status(&state, &cancel);
    let (status_endpoint, status_requests) = spawn_scripted_https_server(
        &tls,
        vec![ScriptedResponse::Json(
            serde_json::to_string(&status_response).expect("cancelled status JSON"),
        )],
    )
    .await;
    let restarted = RemoteExecutionControllerClient::new_for_tests(
        HOST_ID,
        pinned_client(&status_endpoint, &tls),
    );
    let reconciled = temp_env::async_with_vars(
        [(TOKEN_ENV, Some("controller-secret"))],
        restarted.status(&state.prepared.db, &status_request),
    )
    .await
    .expect("cancelled status reconciles after restart");
    assert_eq!(reconciled.0, status_response);
    assert!(matches!(
        reconciled.1,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Cancelled
    ));
    assert_eq!(
        status_requests.await.expect("status request count").len(),
        1
    );
    let replayed = restarted
        .cancel(&state.prepared.db, &cancel)
        .await
        .expect("replay status-reconciled cancellation without I/O");
    assert_eq!(replayed.0.observed_at, status_response.observed_at);
    assert!(matches!(
        replayed.1,
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));

    assert_cancelled_workflow_projection(&state, &pending.assignment_id).await;
}

async fn assert_cancelled_workflow_projection(
    state: &super::controller_prepared_test_support::PreparedLifecycle,
    assignment_id: &str,
) {
    let parent = state
        .prepared
        .db
        .task_board_workflow_execution(&state.prepared.execution_id)
        .await
        .expect("load cancelled workflow")
        .expect("cancelled workflow");
    assert_eq!(
        parent.transition.execution_state,
        TaskBoardExecutionState::Cancelled
    );
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Cancelled);
    assert!(
        !state
            .prepared
            .db
            .task_board_execution_has_active_remote_assignment(&state.prepared.execution_id)
            .await
            .expect("load terminal projection fence")
    );
    assert!(
        state
            .prepared
            .db
            .task_board_remote_settlement_receipt(assignment_id)
            .await
            .expect("load pre-settlement receipt")
            .is_none()
    );
}

fn cancelled_status(
    state: &super::controller_prepared_test_support::PreparedLifecycle,
    cancel: &super::wire::RemoteCancelRequest,
) -> super::wire::RemoteStatusResponse {
    super::wire::RemoteStatusResponse {
        schema_version: super::wire::TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: cancel.binding.clone(),
        state: super::wire::RemoteAssignmentWireState::Cancelled,
        offer_request_sha256: cancel.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(super::wire::RemoteLease {
            lease_id: cancel.lease_id.clone(),
            expires_at: state.times.l1_expires_at.clone(),
        }),
        result: None,
        output_artifacts: super::wire::RemoteArtifactManifest::default(),
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        error_code: Some(cancel.reason.clone()),
        failure_class: None,
        observed_at: state.times.status_observed_at.clone(),
    }
    .seal()
    .expect("seal cancelled status")
}
