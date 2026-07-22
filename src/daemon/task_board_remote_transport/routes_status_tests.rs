use super::controller_authority_test_support::HOST_ID;
use super::controller_prepared_test_support::{
    failed_status, persist_claim, prepared_acceptance, status_request,
};
use super::routes_status::status_response as route_status_response;
use super::wire::RemoteStatusResponse;
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};

#[tokio::test]
async fn failed_route_echoes_exact_durable_failure_class_and_refuses_absence() {
    let state = prepared_acceptance("failed-status-route").await;
    persist_claim(&state).await;
    let request = status_request(&state);
    let response = failed_status(&state, TaskBoardFailureClass::Transient);
    let outcome = state
        .prepared
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST_ID)
        .await
        .expect("persist typed failed status");
    assert!(matches!(
        outcome,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Failed
    ));
    let record = state
        .prepared
        .db
        .task_board_remote_assignment(&state.prepared.offer.binding.assignment_id)
        .await
        .expect("load failed assignment")
        .expect("failed assignment");
    let routed = route_status_response(&record, &request).expect("route durable failed status");
    assert_eq!(routed, response);
    assert_eq!(routed.failure_class, Some(TaskBoardFailureClass::Transient));
    let restored: RemoteStatusResponse = serde_json::from_slice(
        &serde_json::to_vec(&routed).expect("serialize routed failed status"),
    )
    .expect("restore routed failed status");
    assert_eq!(restored, routed);

    let mut missing = response;
    missing.failure_class = None;
    missing = missing.seal().expect("reseal missing class");
    let mut malformed = record;
    malformed.status_response = Some(missing);
    let error = route_status_response(&malformed, &request)
        .expect_err("route refuses failed status without class");
    assert!(error.to_string().contains("failure_class"));
}
