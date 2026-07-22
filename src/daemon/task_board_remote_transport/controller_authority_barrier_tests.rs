use std::sync::Arc;

use super::controller_authority_test_support::{
    BarrierServer, TOKEN_ENV, accepted_offer, apply_stop, central_offer, claim_request,
    claim_response, expired_central_offer, persist_acceptance, pinned_controller,
    pinned_controller_with_times, prepare_stop, spawn_barrier_server, test_tls_material, try_stop,
};
use super::controller_authority_tests::assert_concurrent_database_error;
use crate::daemon::db::{TaskBoardRemoteMutationOutcome, utc_now};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn offer_authority_fences_stop_until_response_settlement() {
    let state = central_offer().await;
    let stale_stop = prepare_stop(&state, "raced offer authority")
        .await
        .expect("capture stop before offer authority");
    let response = accepted_offer(&state);
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("offer response JSON"),
    )
    .await;
    let controller = pinned_controller(&endpoint, &tls);
    let db = state.fixture.db.clone();
    let request = state.fixture.request.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.offer(&db, &request).await });
        seen.await
            .expect("offer reached server after authority claim");
        let stop_error = apply_stop(&state, &stale_stop)
            .await
            .expect_err("offer authority fences stale terminal CAS");
        assert_eq!(stop_error.code(), "WORKFLOW_CONCURRENT");
        release.send(()).expect("release offer response");
        let outcome = call
            .await
            .expect("offer controller task")
            .expect("settle accepted offer");
        assert_eq!(outcome.0, response);
    })
    .await;
    assert_eq!(requests.await.expect("barrier server"), 1);
    try_stop(&state, "stopped after offer settlement")
        .await
        .expect("offer settlement clears operation authority");
}

#[tokio::test]
async fn claim_authority_fences_stop_and_settles_attempt_running() {
    let state = central_offer().await;
    persist_acceptance(&state).await;
    let stale_stop = prepare_stop(&state, "raced claim authority")
        .await
        .expect("capture stop before claim authority");
    let request = claim_request(&state);
    let response = claim_response(&state);
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("claim response JSON"),
    )
    .await;
    let controller = pinned_controller(&endpoint, &tls);
    let db = state.fixture.db.clone();
    let request_for_call = request.clone();

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call = tokio::spawn(async move { controller.claim(&db, &request_for_call).await });
        seen.await
            .expect("claim reached server after authority claim");
        let stop_error = apply_stop(&state, &stale_stop)
            .await
            .expect_err("claim authority fences stale terminal CAS");
        assert_eq!(stop_error.code(), "WORKFLOW_CONCURRENT");
        release.send(()).expect("release claim response");
        let outcome = call
            .await
            .expect("claim controller task")
            .expect("settle accepted claim");
        assert_eq!(outcome.0, response);
    })
    .await;
    assert_eq!(requests.await.expect("barrier server"), 1);
    let execution = state
        .fixture
        .db
        .task_board_workflow_execution(&state.fixture.execution.execution_id)
        .await
        .expect("load claimed execution")
        .expect("claimed execution exists");
    let attempt = execution
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == request.binding.action_key)
        .expect("claimed attempt");
    assert_eq!(attempt.state, TaskBoardAttemptState::Running);
}

#[tokio::test]
async fn expired_accepted_offer_is_retained_but_claim_has_zero_network_io() {
    let state = expired_central_offer().await;
    let response = accepted_offer(&state);
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("offer response JSON"),
    )
    .await;
    let controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [state.offered_at.clone(), utc_now(), utc_now()],
    ));

    let claim_error = temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call_controller = Arc::clone(&controller);
        let db = state.fixture.db.clone();
        let request = state.fixture.request.clone();
        let call = tokio::spawn(async move { call_controller.offer(&db, &request).await });
        seen.await.expect("late offer reached server before expiry");
        release.send(()).expect("release offer after expiry");
        let first = call
            .await
            .expect("late offer controller task")
            .expect("retain late accepted offer");
        assert_eq!(first.0, response);
        assert!(matches!(
            first.1,
            TaskBoardRemoteMutationOutcome::Updated(_)
        ));
        let replay = controller
            .offer(&state.fixture.db, &state.fixture.request)
            .await
            .expect("replay immutable late acceptance");
        assert_eq!(replay.0, response);
        assert!(matches!(
            replay.1,
            TaskBoardRemoteMutationOutcome::Replayed(_)
        ));
        controller
            .claim(&state.fixture.db, &claim_request(&state))
            .await
            .expect_err("expired L1 must fail before claim network I/O")
    })
    .await;
    assert_concurrent_database_error(claim_error);
    assert_eq!(requests.await.expect("replay server"), 1);
    let durable = state
        .fixture
        .db
        .task_board_remote_assignment(&state.fixture.request.binding.assignment_id)
        .await
        .expect("load late acceptance")
        .expect("late acceptance exists");
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Superseded);
    assert_eq!(durable.lease_id.as_deref(), Some("lease-l1"));
    let execution = state
        .fixture
        .db
        .task_board_workflow_execution(&state.fixture.execution.execution_id)
        .await
        .expect("load late acceptance execution")
        .expect("late acceptance execution exists");
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(execution.attempts.len(), 2);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    assert_eq!(execution.attempts[1].state, TaskBoardAttemptState::Starting);
}
