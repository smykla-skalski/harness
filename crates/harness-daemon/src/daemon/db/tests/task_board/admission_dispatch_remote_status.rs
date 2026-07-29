use super::completion_evidence_tests::{intent_status, remote_status, remote_status_request};
use super::remote_start_tests::{
    PreparedRemoteOffer, persist_remote_start, prepare_remote_offer_with_policy,
    prepare_remote_offer_with_retry,
};
use super::{AsyncDaemonDb, ledger_kind_state};
use crate::daemon::db::task_board::remote_assignment_test_support::claim_request;
use crate::daemon::db::task_board::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOperationKind};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteOfferRequest, RemoteStatusResponse, RemoteTypedResult,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
    TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome,
};

#[tokio::test]
async fn running_status_after_lost_claim_response_promotes_and_commits_start_once() {
    let prepared = prepare_lost_claim_running_status().await;
    let response = remote_status(&prepared.offer, RemoteAssignmentWireState::Running, true);
    record_status(&prepared, &response).await;
    assert_committed_start(&prepared).await;
    let execution = load_execution(&prepared.db, &prepared.execution_id).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert!(
        !execution
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
    );
    assert!(
        !prepared
            .db
            .complete_task_board_workflow_dispatch_start(&prepared.execution_id)
            .await
            .expect("status already settled prepared start")
    );
    assert_status_replay_is_noop(&prepared, &response).await;
    let renewal = prepared
        .db
        .build_task_board_remote_renew_request(&prepared.offer.binding.assignment_id)
        .await
        .expect("build renewal after status adoption")
        .expect("running assignment can renew");
    assert!(
        prepared
            .db
            .claim_task_board_remote_renew_io_authority(
                &renewal,
                "executor-a",
                "2026-07-19T10:00:05Z",
            )
            .await
            .expect("claim renewal authority")
            .is_some()
    );
}

async fn prepare_lost_claim_running_status() -> PreparedRemoteOffer {
    let prepared = prepare_remote_offer_with_policy("admission-remote-lost-claim", true).await;
    super::remote_start_tests::offer_remote(
        &prepared,
        "2026-07-19T10:00:00Z",
        "2026-07-19T10:01:00Z",
    )
    .await
    .expect("offer remote assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &super::completion_evidence_tests::accepted_offer(&prepared.offer),
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    let accepted = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load accepted assignment")
        .expect("accepted assignment");
    let claim = claim_request(&prepared.offer, &accepted);
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(
            &claim,
            "executor-a",
            "2026-07-19T10:00:01.500Z",
        )
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    prepared
        .db
        .complete_task_board_remote_operation_trust(
            &prepared.offer.binding.assignment_id,
            TaskBoardRemoteOperationKind::Claim,
            &claim.request_sha256,
        )
        .await
        .expect("release completed claim transport trust");
    let status_request = remote_status_request(&prepared.offer);
    assert!(
        prepared
            .db
            .claim_task_board_remote_status_io_authority(&status_request, "executor-a")
            .await
            .expect("claim exact status operation trust")
    );
    prepared
}

#[tokio::test]
async fn completed_remote_status_is_provisional_and_keeps_remote_ownership() {
    let prepared = prepare_remote_offer_with_policy("admission-remote-completed", true).await;
    persist_remote_start(&prepared).await;
    let parent = load_execution(&prepared.db, &prepared.execution_id).await;
    let ledger = admission_ledger_snapshot(&prepared.db, &prepared.intent).await;
    let response = completed_status(&prepared.offer);
    record_status(&prepared, &response).await;

    assert_committed_start(&prepared).await;
    let execution = load_execution(&prepared.db, &prepared.execution_id).await;
    assert_eq!(execution, parent);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:"))
    );
    assert_eq!(
        admission_ledger_snapshot(&prepared.db, &prepared.intent).await,
        ledger
    );
    let assignment = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load provisional completed assignment")
        .expect("completed assignment");
    assert_eq!(assignment.status_response.as_ref(), Some(&response));
    assert_eq!(
        assignment.result_sha256,
        response
            .result
            .as_ref()
            .map(|result| result.result_sha256.clone())
    );
    assert_status_replay_is_noop(&prepared, &response).await;
}

#[tokio::test]
async fn transient_remote_failure_does_not_schedule_retry_before_result_adoption() {
    let prepared = prepare_remote_offer_with_policy("admission-remote-retry", true).await;
    persist_remote_start(&prepared).await;
    let parent = load_execution(&prepared.db, &prepared.execution_id).await;
    let ledger = admission_ledger_snapshot(&prepared.db, &prepared.intent).await;
    let response = failed_status(&prepared.offer, TaskBoardFailureClass::Transient);
    record_status(&prepared, &response).await;

    assert_committed_start(&prepared).await;
    let reopened = prepared.db.reopen().await;
    let execution = load_execution(&reopened, &prepared.execution_id).await;
    assert_eq!(execution, parent);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(execution.artifacts.retry, None);
    assert!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:"))
    );
    assert_eq!(
        admission_ledger_snapshot(&prepared.db, &prepared.intent).await,
        ledger
    );
    assert_status_replay_is_noop(&prepared, &response).await;
}

#[tokio::test]
async fn exhausted_transient_observation_does_not_release_concurrency_or_stop_parent() {
    let prepared =
        prepare_remote_offer_with_retry("admission-remote-exhausted", true, Some(1)).await;
    persist_remote_start(&prepared).await;
    let parent = load_execution(&prepared.db, &prepared.execution_id).await;
    let response = failed_status(&prepared.offer, TaskBoardFailureClass::Transient);
    record_status(&prepared, &response).await;

    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "completed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "committed"
    );
    let execution = load_execution(&prepared.db, &prepared.execution_id).await;
    assert_eq!(execution, parent);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_status_replay_is_noop(&prepared, &response).await;
}

async fn assert_committed_start(prepared: &PreparedRemoteOffer) {
    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "completed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "committed"
    );
}

async fn record_status(prepared: &PreparedRemoteOffer, response: &RemoteStatusResponse) {
    assert!(matches!(
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                response,
                "executor-a",
            )
            .await
            .expect("record remote terminal status"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

async fn assert_status_replay_is_noop(
    prepared: &PreparedRemoteOffer,
    response: &RemoteStatusResponse,
) {
    let sequence = prepared
        .db
        .current_change_sequence()
        .await
        .expect("load settled sequence");
    let ledger = admission_ledger_snapshot(&prepared.db, &prepared.intent).await;
    assert!(matches!(
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                response,
                "executor-a",
            )
            .await
            .expect("replay remote terminal status"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    assert_eq!(
        prepared
            .db
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
    assert_eq!(
        admission_ledger_snapshot(&prepared.db, &prepared.intent).await,
        ledger
    );
}

async fn admission_ledger_snapshot(
    db: &AsyncDaemonDb,
    intent_id: &str,
) -> Vec<(String, String, Option<String>, Option<String>)> {
    sqlx::query_as(
        "SELECT kind, state, committed_at, released_at
         FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 ORDER BY canonical_key",
    )
    .bind(intent_id)
    .fetch_all(db.pool())
    .await
    .expect("load admission ledger snapshot")
}

async fn load_execution(
    db: &AsyncDaemonDb,
    execution_id: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    db.task_board_workflow_execution(execution_id)
        .await
        .expect("load workflow execution")
        .expect("workflow execution exists")
}

fn completed_status(offer: &RemoteOfferRequest) -> RemoteStatusResponse {
    let result = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: offer.binding.execution_id.clone(),
        action_key: offer.binding.action_key.clone(),
        attempt: offer.binding.attempt,
        idempotency_key: offer.binding.idempotency_key.clone(),
        exact_head_revision: "1111111111111111111111111111111111111111".into(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: offer
                .binding
                .action_key
                .strip_prefix("review:")
                .expect("review action key")
                .into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: "1111111111111111111111111111111111111111".into(),
                summary: "remote review passed".into(),
                findings: Vec::new(),
            },
        }),
    };
    let mut response = remote_status(offer, RemoteAssignmentWireState::Running, true);
    response.state = RemoteAssignmentWireState::Completed;
    response.result = Some(
        RemoteTypedResult::seal(result, offer.request_sha256.clone()).expect("seal typed result"),
    );
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.status_sha256.clear();
    response.seal().expect("seal completed status")
}

fn failed_status(
    offer: &RemoteOfferRequest,
    failure_class: TaskBoardFailureClass,
) -> RemoteStatusResponse {
    let mut response = remote_status(offer, RemoteAssignmentWireState::Running, true);
    response.state = RemoteAssignmentWireState::Failed;
    response.error_code = Some("remote_failed".into());
    response.failure_class = Some(failure_class);
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.status_sha256.clear();
    response.seal().expect("seal failed status")
}
