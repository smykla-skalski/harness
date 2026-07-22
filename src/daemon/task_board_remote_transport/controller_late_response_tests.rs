use std::sync::Arc;

use super::controller_authority_test_support::{
    BarrierServer, TOKEN_ENV, pinned_controller_with_times, spawn_barrier_server, test_tls_material,
};
use super::controller_authority_tests::assert_concurrent_database_error;
use super::controller_prepared_test_support::{
    PreparedLifecycle, claim_request, claim_response, persist_claim, prepared_acceptance,
    renewal_request, renewal_response,
};
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn claim_response_received_after_l1_expiry_never_exposes_running_state() {
    let state = prepared_acceptance("late-claim-response").await;
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
    let controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.after_expiry.clone(),
        ],
    ));

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call_controller = Arc::clone(&controller);
        let db = (*state.prepared.db).clone();
        let request_for_call = request.clone();
        let call = tokio::spawn(async move { call_controller.claim(&db, &request_for_call).await });
        seen.await.expect("claim reached executor before expiry");
        release.send(()).expect("release claim after expiry");
        let outcome = call
            .await
            .expect("late claim controller task")
            .expect("retain late claim evidence");
        assert_eq!(outcome.0, response);
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Unknown
                    && record.claimed_at.as_deref()
                        == Some(state.times.before_expiry.as_str())
        ));
        let replay = controller
            .claim(&state.prepared.db, &request)
            .await
            .expect("replay immutable late claim receipt");
        assert_eq!(replay.0, response);
        assert!(matches!(
            replay.1,
            TaskBoardRemoteMutationOutcome::Replayed(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Unknown
        ));
    })
    .await;
    assert_eq!(requests.await.expect("late claim server"), 1);
    assert_human_required_unknown(&state).await;
}

#[tokio::test]
async fn renewal_response_received_after_l1_expiry_retains_l2_but_stops_continuation() {
    let state = prepared_acceptance("late-renewal-response").await;
    persist_claim(&state).await;
    let request = renewal_request(&state);
    let response = renewal_response(&state);
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&response).expect("renewal response JSON"),
    )
    .await;
    let controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.after_expiry.clone(),
        ],
    ));

    let replay_error = temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let call_controller = Arc::clone(&controller);
        let db = (*state.prepared.db).clone();
        let request_for_call = request.clone();
        let call =
            tokio::spawn(async move { call_controller.renew_lease(&db, &request_for_call).await });
        seen.await
            .expect("renewal reached executor before L1 expiry");
        release.send(()).expect("release L2 after L1 expiry");
        let outcome = call
            .await
            .expect("late renewal controller task")
            .expect("retain late L2 evidence");
        assert_eq!(outcome.0, response);
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Unknown
                    && record.lease_id.as_deref() == Some("lease-l2")
                    && record.lease_expires_at.as_deref()
                        == Some(state.times.l2_expires_at.as_str())
        ));
        controller
            .renew_lease(&state.prepared.db, &request)
            .await
            .expect_err("unknown renewal cannot regain network authority")
    })
    .await;
    assert_concurrent_database_error(replay_error);
    assert_eq!(requests.await.expect("late renewal server"), 1);
    assert_human_required_unknown(&state).await;
}

async fn assert_human_required_unknown(state: &PreparedLifecycle) {
    let execution = state
        .prepared
        .db
        .task_board_workflow_execution(&state.prepared.execution_id)
        .await
        .expect("load late response execution")
        .expect("late response execution exists");
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    let attempt = execution
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == state.prepared.offer.binding.action_key)
        .expect("late response attempt");
    assert_eq!(attempt.state, TaskBoardAttemptState::Unknown);
}
