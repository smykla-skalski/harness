use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
    TaskBoardRemoteOfferReceiptDisposition,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteOfferRequest,
    RemoteSourceMaterial, RemoteStatusRequest, RemoteStatusResponse, RemoteTypedResult,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardLocalExecutionRepositoryConfig, TaskBoardPhaseVerdict,
    TaskBoardRemoteAssignmentState, TaskBoardReviewResult, TaskBoardReviewerOutcome,
    TaskBoardWorkflowKind,
};

const FORK_REPOSITORY: &str = "contributor/harness";
const FORK_CHECKOUT: &str = "/tmp/harness-remote-fork";

#[tokio::test]
async fn fork_offer_requires_and_freezes_the_exact_source_repository_checkout() {
    let base_only = executor_fixture(1).await;
    let rejected_request = fork_offer("assignment-fork-rejected", "fork-rejected");
    assert!(matches!(
        base_only
            .db
            .accept_task_board_remote_assignment_offer(
                &rejected_request,
                PRINCIPAL,
                INSTANCE,
                NOW,
            )
            .await
            .expect("reject fork offer without a fork checkout"),
        TaskBoardRemoteOfferOutcome::Rejected(_)
    ));
    assert!(
        base_only
            .db
            .task_board_remote_assignment(&rejected_request.binding.assignment_id)
            .await
            .expect("load rejected fork assignment")
            .is_none()
    );

    let configured = executor_fixture(1).await;
    let mut settings = configured
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.repositories.push(
        TaskBoardLocalExecutionRepositoryConfig {
            repository: FORK_REPOSITORY.into(),
            checkout_path: FORK_CHECKOUT.into(),
        },
    );
    settings
        .local_execution_host
        .repositories
        .sort_by(|left, right| left.repository.cmp(&right.repository));
    configured
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure fork checkout");
    let accepted_request = fork_offer("assignment-fork-accepted", "fork-accepted");
    let accepted = accept_executor(&configured, &accepted_request).await;
    assert_eq!(
        accepted.require_offer().expect("sealed offer").binding.repository,
        FORK_REPOSITORY
    );
    assert_eq!(accepted.executor_checkout_path.as_deref(), Some(FORK_CHECKOUT));
    configured
        .db
        .claim_task_board_remote_assignment(
            &claim_request(&accepted_request, &accepted),
            PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim fork assignment");
    assert!(matches!(
        authorize_and_start_executor(&configured, &accepted.assignment_id, STARTED_AT).await,
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

fn fork_offer(assignment_id: &str, idempotency_key: &str) -> RemoteOfferRequest {
    let mut request = detached_offer(assignment_id, idempotency_key);
    request.binding.workflow_kind = TaskBoardWorkflowKind::PrReview;
    // The binding repository tracks the fork source the checkout is frozen against.
    request.binding.repository = FORK_REPOSITORY.into();
    request.source = RemoteSourceMaterial::repository_branch(
        FORK_REPOSITORY,
        "feature/fix",
        SOURCE_REVISION,
    );
    request.request_sha256.clear();
    request.seal().expect("seal fork offer")
}

#[tokio::test]
async fn lost_acceptance_replays_after_settings_change_but_start_fails_before_io() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    assert!(accepted.executor_configuration_revision.is_some());
    assert_eq!(
        accepted.executor_checkout_path.as_deref(),
        Some("/tmp/harness-remote-checkouts")
    );
    change_executor_capacity(&fixture, 2).await;

    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &fixture.request,
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:05Z",
            )
            .await
            .expect("replay lost acceptance"),
        TaskBoardRemoteOfferOutcome::AcceptedReplay(receipt)
            if receipt.request == fixture.request
                && receipt.disposition == TaskBoardRemoteOfferReceiptDisposition::Accepted
                && receipt.initial_lease_id == accepted.lease_id
                && receipt.initial_lease_expires_at == accepted.lease_expires_at
    ));
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim accepted assignment");
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                STARTED_AT,
            )
            .await
            .expect("reject start authority with changed settings")
            .is_none()
    );
    let durable = load_assignment(&fixture, &accepted.assignment_id).await;
    // A settings change before start revokes the claim to Unknown for recovery under the new generation.
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Unknown);
    assert_eq!(durable.claimed_at.as_deref(), Some(CLAIMED_AT));
    assert_eq!(durable.started_at, None);
    assert_eq!(durable.workspace_ref, None);
}

#[tokio::test]
async fn claim_then_host_crash_stays_unstarted_and_recovers_unknown_without_capacity_reuse() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim assignment");

    let claimed = load_assignment(&fixture, &accepted.assignment_id).await;
    assert_eq!(claimed.claimed_at.as_deref(), Some(CLAIMED_AT));
    assert_eq!(
        (
            claimed.started_at.as_deref(),
            claimed.workspace_ref.as_deref()
        ),
        (None, None)
    );
    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover claimed assignment");
    assert!(recovered.failures.is_empty());
    assert_eq!(recovered.recovered.len(), 1);
    assert_eq!(
        recovered.recovered[0].state,
        TaskBoardRemoteAssignmentState::Unknown
    );
    assert_eq!(
        recovered.recovered[0].claimed_at.as_deref(),
        Some(CLAIMED_AT)
    );
    assert_eq!(recovered.recovered[0].started_at, None);

    assert_unknown_assignment_keeps_capacity(&fixture).await;
}

async fn assert_unknown_assignment_keeps_capacity(fixture: &ExecutorFixture) {
    let mut second = detached_offer("assignment-executor-2", "attempt-key-2");
    second.binding.execution_id = "execution-detached-2".into();
    second.launch = test_codex_launch(
        crate::task_board::TaskBoardExecutionPhase::Review,
        "execution-detached-2",
        "review:reviewer",
        "Review the frozen revision",
    );
    second.request_sha256.clear();
    let second = second.seal().expect("reseal independent assignment");
    let rejected = match fixture
        .db
        .accept_task_board_remote_assignment_offer(&second, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("offer while unknown consumes capacity")
    {
        TaskBoardRemoteOfferOutcome::Rejected(record) => record,
        other => panic!("expected durable rejection, got {other:?}"),
    };
    assert_eq!(rejected.request, second);
    assert_eq!(rejected.authenticated_principal, PRINCIPAL);
    assert_eq!(
        rejected.disposition,
        TaskBoardRemoteOfferReceiptDisposition::Rejected
    );
    assert_eq!(rejected.initial_lease_id, None);
    assert_eq!(rejected.initial_lease_expires_at, None);
    assert_eq!(
        rejected.rejection_code.as_deref(),
        Some("executor_unavailable")
    );
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&second.binding.assignment_id)
            .await
            .expect("load rejected assignment")
            .is_none()
    );

    change_executor_capacity(&fixture, 2).await;
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(&second, PRINCIPAL, INSTANCE, NOW)
            .await
            .expect("replay rejection after capacity changes"),
        TaskBoardRemoteOfferOutcome::Rejected(record) if record == rejected
    ));
    let mut conflicting = second.clone();
    conflicting.launch.prompt = "Changed request content".into();
    conflicting.request_sha256.clear();
    let conflicting = conflicting.seal().expect("reseal conflicting offer");
    assert!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(&conflicting, PRINCIPAL, INSTANCE, NOW)
            .await
            .expect_err("different request digest must fail closed")
            .to_string()
            .contains("conflicting immutable offer evidence")
    );
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence"),
        sequence
    );
}

#[tokio::test]
async fn expired_unclaimed_host_offer_is_safely_superseded() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;

    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover unclaimed host offer");

    assert!(recovered.failures.is_empty());
    assert_eq!(recovered.recovered.len(), 1);
    assert_eq!(recovered.recovered[0].assignment_id, accepted.assignment_id);
    assert_eq!(
        recovered.recovered[0].state,
        TaskBoardRemoteAssignmentState::Superseded
    );
    assert_eq!(recovered.recovered[0].claimed_at, None);
}

#[tokio::test]
async fn started_evidence_and_typed_terminal_status_survive_unknown_reconciliation() {
    let fixture = controller_fixture(1).await;
    let accepted = super::remote_assignment_generation_tests::accept_controller(&fixture).await;
    let claimed =
        super::remote_assignment_generation_tests::claim_controller(&fixture, &accepted).await;
    let running_request =
        super::remote_assignment_generation_tests::status_request(&fixture.request, &claimed);
    let running =
        super::remote_assignment_generation_tests::running_status(&running_request, &claimed);
    fixture
        .db
        .record_task_board_remote_assignment_status(&running_request, &running, HOST)
        .await
        .expect("record durable start evidence");
    fixture
        .db
        .mark_task_board_remote_assignment_unknown(
            &fixture.request.binding,
            "controller lost status response",
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("mark ambiguous outcome");
    let unknown = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load ambiguous assignment")
        .expect("ambiguous assignment");
    let status_request = status_request(&fixture.request, &unknown);
    let response = completed_status(&fixture.request, &unknown);

    let updated = fixture
        .db
        .record_task_board_remote_assignment_status(&status_request, &response, HOST)
        .await
        .expect("record authoritative terminal status");
    assert!(matches!(
        updated,
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Completed
                && record.claimed_at.as_deref() == Some(CLAIMED_AT)
                && record.started_at.as_deref() == Some(STARTED_AT)
                && record.workspace_ref.as_deref() == Some("workspace-1")
                && record.result_sha256.is_some()
    ));
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    let mut conflicting = response.clone();
    conflicting.observed_at = "2026-07-19T10:00:41Z".into();
    let conflicting = conflicting
        .seal()
        .expect("reseal conflicting terminal status");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(
                &status_request,
                &conflicting,
                HOST,
            )
            .await
            .expect("reject conflicting terminal status"),
        TaskBoardRemoteMutationOutcome::Stale(record)
            if record.status_response.as_ref() == Some(&response)
                && record.status_sha256.as_deref() == Some(response.status_sha256.as_str())
    ));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence"),
        sequence
    );
}

async fn load_assignment(
    fixture: &ExecutorFixture,
    assignment_id: &str,
) -> super::TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load assignment")
        .expect("assignment")
}

async fn change_executor_capacity(fixture: &ExecutorFixture, capacity: u32) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capacity = capacity;
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("change executor settings");
}

fn completed_status(
    request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusResponse {
    let result = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: request.binding.execution_id.clone(),
        action_key: request.binding.action_key.clone(),
        attempt: request.binding.attempt,
        idempotency_key: request.binding.idempotency_key.clone(),
        exact_head_revision: SOURCE_REVISION.into(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: SOURCE_REVISION.into(),
                summary: "review passed".into(),
                findings: Vec::new(),
            },
        }),
    };
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Completed,
        offer_request_sha256: request.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: assignment.lease_id.clone().expect("lease"),
            expires_at: assignment.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: Some(
            RemoteTypedResult::seal(result, request.request_sha256.clone())
                .expect("seal typed result"),
        ),
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some(STARTED_AT.into()),
        workspace_ref: Some("workspace-1".into()),
        error_code: None,
        failure_class: None,
        observed_at: "2026-07-19T10:00:40Z".into(),
    }
    .seal()
    .expect("seal completed status")
}

fn status_request(
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("assignment lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status request")
}
