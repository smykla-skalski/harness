use std::sync::Arc;

use super::controller_authority_test_support::{
    TOKEN_ENV, pinned_controller, pinned_controller_with_times, spawn_barrier_server,
    spawn_probe_server, test_tls_material,
};
use super::controller_authority_tests::assert_concurrent_database_error;
use super::controller_prepared_test_support::{
    completed_status, persist_claim, prepared_acceptance, status_request,
};
use super::controller_tests::{cancel_request, cancel_response};
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::task_board::{
    TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE, TaskBoardAttemptState,
    TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn status_authority_wins_before_cancel_and_cancel_performs_zero_io() {
    let state = prepared_acceptance("status-before-cancel-authority").await;
    persist_claim(&state).await;
    let status = status_request(&state);
    let status_response = completed_status(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let tls = test_tls_material();
    let status_server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&status_response).expect("status response JSON"),
    )
    .await;
    let (cancel_endpoint, cancel_requests) = spawn_probe_server(&tls).await;
    let status_controller = Arc::new(pinned_controller(&status_server.endpoint, &tls));
    let cancel_controller = Arc::new(pinned_controller_with_times(
        &cancel_endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let status_call = spawn_status(&status_controller, &state, &status);
        status_server
            .seen
            .await
            .expect("status request reached executor");
        let cancel_error = cancel_controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect_err("status authority must exclude cancellation");
        assert_concurrent_database_error(cancel_error);
        status_server.release.send(()).expect("release status");
        let status_outcome = status_call
            .await
            .expect("status task")
            .expect("status settles atomically");
        assert!(matches!(
            status_outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Completed
        ));
    })
    .await;
    assert_eq!(status_server.requests.await.expect("status barrier"), 1);
    assert_eq!(cancel_requests.await.expect("cancel probe"), 0);
}

#[tokio::test]
async fn journaled_cancel_lets_a_reconciling_status_reach_the_executor() {
    let state = prepared_acceptance("cancel-authority-before-status").await;
    persist_claim(&state).await;
    let status = status_request(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let cancel_response = cancel_response(&state.prepared.offer, &state.times.before_expiry);
    let tls = test_tls_material();
    let cancel_server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&cancel_response).expect("cancel response JSON"),
    )
    .await;
    let (status_endpoint, status_requests) = spawn_probe_server(&tls).await;
    let cancel_controller = Arc::new(pinned_controller_with_times(
        &cancel_server.endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));
    let status_controller = Arc::new(pinned_controller(&status_endpoint, &tls));

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let cancel_call = spawn_cancel(&cancel_controller, &state, &cancel);
        cancel_server.seen.await.expect("cancel acquired authority");
        // A journaled cancel is durable and indistinguishable from one whose controller
        // died, so a concurrent status is not database-excluded (unlike the reverse
        // direction): it adopts the journaled cancel and reaches the executor to
        // reconcile it, keeping a crashed cancel recoverable. The exclusive settle stays
        // single-writer, so the redundant probe cannot double-apply the terminal state.
        let status_error = status_controller
            .status(&state.prepared.db, &status)
            .await
            .expect_err("reconciling status reaches the executor and its probe fails");
        assert!(
            matches!(
                status_error,
                super::controller::RemoteExecutionControllerError::Transport(_)
            ),
            "status must reconcile past the database fence, got {status_error:?}"
        );
        cancel_server.release.send(()).expect("release cancel");
        cancel_call
            .await
            .expect("cancel task")
            .expect("cancel settles atomically");
    })
    .await;
    assert_eq!(status_requests.await.expect("status probe"), 1);
    assert_eq!(cancel_server.requests.await.expect("cancel barrier"), 1);
    assert_cancelled_without_authority(&state).await;
}

#[tokio::test]
async fn completed_status_before_cancel_denies_cancel_with_zero_io() {
    let state = prepared_acceptance("completed-status-before-cancel").await;
    persist_claim(&state).await;
    let status = status_request(&state);
    let status_response = completed_status(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let tls = test_tls_material();
    let status_server = spawn_barrier_server(
        &tls,
        serde_json::to_string(&status_response).expect("status response JSON"),
    )
    .await;
    let (cancel_endpoint, cancel_requests) = spawn_probe_server(&tls).await;
    let status_controller = pinned_controller(&status_server.endpoint, &tls);
    let cancel_controller =
        pinned_controller_with_times(&cancel_endpoint, &tls, [state.times.before_expiry.clone()]);

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let status_call = status_controller.status(&state.prepared.db, &status);
        let release_status = async {
            status_server.seen.await.expect("status reached executor");
            status_server.release.send(()).expect("release status");
        };
        let (outcome, ()) = tokio::join!(status_call, release_status);
        let outcome = outcome.expect("terminal status settles atomically");
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Completed
        ));
        let error = cancel_controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect_err("completed status must fence later cancellation");
        assert_concurrent_database_error(error);
    })
    .await;
    assert_eq!(status_server.requests.await.expect("status barrier"), 1);
    assert_eq!(cancel_requests.await.expect("cancel probe"), 0);
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load completed assignment")
        .expect("completed assignment");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Completed);
}

fn spawn_status(
    controller: &Arc<super::controller::RemoteExecutionControllerClient>,
    state: &super::controller_prepared_test_support::PreparedLifecycle,
    request: &super::wire::RemoteStatusRequest,
) -> tokio::task::JoinHandle<
    Result<
        (
            super::wire::RemoteStatusResponse,
            TaskBoardRemoteMutationOutcome,
        ),
        super::controller::RemoteExecutionControllerError,
    >,
> {
    let controller = Arc::clone(controller);
    let db = (*state.prepared.db).clone();
    let request = request.clone();
    tokio::spawn(async move { controller.status(&db, &request).await })
}

fn spawn_cancel(
    controller: &Arc<super::controller::RemoteExecutionControllerClient>,
    state: &super::controller_prepared_test_support::PreparedLifecycle,
    request: &super::wire::RemoteCancelRequest,
) -> tokio::task::JoinHandle<
    Result<
        (
            super::wire::RemoteCancelResponse,
            TaskBoardRemoteMutationOutcome,
        ),
        super::controller::RemoteExecutionControllerError,
    >,
> {
    let controller = Arc::clone(controller);
    let db = (*state.prepared.db).clone();
    let request = request.clone();
    tokio::spawn(async move { controller.cancel(&db, &request).await })
}

async fn assert_cancelled_without_authority(
    state: &super::controller_prepared_test_support::PreparedLifecycle,
) {
    let assignment = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load cancelled assignment")
        .expect("cancelled assignment");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Cancelled);
    let execution = state
        .prepared
        .db
        .task_board_workflow_execution(&state.prepared.execution_id)
        .await
        .expect("load cancelled execution")
        .expect("cancelled execution");
    let attempt = execution
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == state.prepared.offer.binding.action_key)
        .expect("cancelled attempt");
    assert_eq!(attempt.state, TaskBoardAttemptState::Cancelled);
    assert!(
        !execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE)
    );
}
