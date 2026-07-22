use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::{
    accept_controller, claim_controller, running_status, status_request,
};
use super::remote_assignment_test_support::{
    AFTER_EXPIRY, CLAIMED_AT, ControllerFixture, HOST, STARTED_AT, controller_fixture,
    controller_fixture_with_retry_attempts, claim_request,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteStatusRequest,
    RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn terminal_failure_is_provisional_and_immutable_across_restart() {
    let (fixture, request, running) = running_controller().await;
    let response = failure_status(&request, &running, TaskBoardFailureClass::Transient);
    let parent = load_execution(&fixture).await;

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("record transient remote failure"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Failed
    ));
    assert_eq!(load_execution(&fixture).await, parent);
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load provisional sequence");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("replay exact provisional failure"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
    let mut conflicting = response.clone();
    conflicting.observed_at = "2026-07-19T10:00:31Z".into();
    conflicting.status_sha256.clear();
    let conflicting = conflicting.seal().expect("reseal conflicting failure");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &conflicting, HOST)
            .await
            .expect("reject conflicting terminal observation"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert_eq!(load_execution(&fixture).await, parent);

    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("controller.db"))
        .await
        .expect("reopen controller database");
    assert_eq!(
        reopened
            .task_board_workflow_execution(&fixture.execution.execution_id)
            .await
            .expect("load reopened execution")
            .expect("reopened execution"),
        parent
    );
}

#[tokio::test]
async fn non_retryable_remote_failures_remain_provisional_until_verified() {
    for failure_class in [
        TaskBoardFailureClass::Permanent,
        TaskBoardFailureClass::Authentication,
        TaskBoardFailureClass::Configuration,
        TaskBoardFailureClass::Policy,
        TaskBoardFailureClass::Conflict,
    ] {
        let (fixture, request, running) = running_controller().await;
        let response = failure_status(&request, &running, failure_class);
        let parent = load_execution(&fixture).await;
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("record non-retryable remote failure");
        assert_eq!(load_execution(&fixture).await, parent);
    }
}

#[tokio::test]
async fn exhausted_transient_failure_remains_provisional_until_verified() {
    let fixture = controller_fixture_with_retry_attempts(1, Some(1)).await;
    let (fixture, request, running) = running_controller_from(fixture).await;
    let response = failure_status(&request, &running, TaskBoardFailureClass::Transient);
    let parent = load_execution(&fixture).await;
    fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect("record exhausted transient failure");
    assert_eq!(load_execution(&fixture).await, parent);
}

#[tokio::test]
async fn raw_cancelled_and_unknown_statuses_cannot_terminate_a_running_assignment() {
    for wire_state in [
        RemoteAssignmentWireState::Cancelled,
        RemoteAssignmentWireState::Unknown,
    ] {
        let (fixture, request, running) = running_controller().await;
        let response = ambiguous_terminal_status(&request, &running, wire_state);
        let parent = load_execution(&fixture).await;

        // Cancelled is a controller determination and Unknown is recovery-only; a raw
        // executor status must not drive an active assignment terminal, which would
        // strand the parent Running with no handoff and leak host capacity forever.
        assert!(matches!(
            fixture
                .db
                .record_task_board_remote_assignment_status(&request, &response, HOST)
                .await
                .expect("reject raw terminal status without controller intent"),
            TaskBoardRemoteMutationOutcome::Stale(record)
                if record.state == TaskBoardRemoteAssignmentState::Running
        ));
        assert_eq!(load_execution(&fixture).await, parent);
    }
}

#[tokio::test]
async fn definitive_status_after_unknown_recovery_preserves_human_required() {
    let (fixture, _, _) = running_controller().await;
    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover expired running assignment");
    assert!(recovered.failures.is_empty());
    let unknown = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load recovered assignment")
        .expect("recovered assignment");
    let request = status_request(&fixture.request, &unknown);
    let mut response = failure_status(&request, &unknown, TaskBoardFailureClass::Permanent);
    response.observed_at = "2026-07-19T10:02:10Z".into();
    response.status_sha256.clear();
    let response = response.seal().expect("reseal definitive late status");
    let parent = load_execution(&fixture).await;

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("retain definitive late status"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Failed
    ));
    let retained_parent = load_execution(&fixture).await;
    assert_eq!(retained_parent, parent);
    assert_eq!(
        retained_parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(retained_parent.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert!(
        retained_parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:"))
    );
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("replay definitive late status"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
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

#[tokio::test]
async fn raw_preclaim_superseded_status_is_rejected() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = status_request(&fixture.request, &accepted);
    let response = superseded_status(&request, &accepted, false);
    let parent = load_execution(&fixture).await;

    // Superseded is a controller-only determination; a raw executor status cannot supersede.
    assert!(matches!(fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect("reject raw preclaim superseded status"),
        TaskBoardRemoteMutationOutcome::Stale(record)
            if record.state != TaskBoardRemoteAssignmentState::Superseded
    ));
    let execution = load_execution(&fixture).await;
    assert_eq!(execution, parent);
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Starting);
    assert!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_some_and(|target| target.starts_with("remote:"))
    );
}

#[tokio::test]
async fn raw_superseded_status_with_lost_claim_evidence_is_rejected() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&claim, HOST, "2026-07-19T10:00:05Z")
        .await
        .expect("claim exact remote claim I/O authority")
        .expect("claim remains eligible");
    let request = status_request(&fixture.request, &accepted);
    let response = superseded_status(&request, &accepted, true);
    assert!(
        fixture
            .db
            .claim_task_board_remote_status_io_authority(&request, HOST)
            .await
            .expect("handoff pending claim trust to status")
    );
    let parent = load_execution(&fixture).await;

    // A raw superseded status cannot terminate the assignment even carrying lost-claim
    // evidence, and it must not synthesize a durable claim receipt.
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("reject raw superseded status"),
        TaskBoardRemoteMutationOutcome::Stale(record)
            if record.state != TaskBoardRemoteAssignmentState::Superseded
    ));
    let execution = load_execution(&fixture).await;
    assert_eq!(execution, parent);
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Starting);
    assert!(
        fixture
            .db
            .exact_task_board_remote_claim_receipt(&claim, HOST)
            .await
            .expect("load claim receipt")
            .is_none()
    );
}

#[tokio::test]
async fn lost_claim_status_requires_the_exact_l1_lease() {
    for mismatch in ["missing", "wrong"] {
        let fixture = controller_fixture(1).await;
        let accepted = accept_controller(&fixture).await;
        let claim = claim_request(&fixture.request, &accepted);
        fixture
            .db
            .claim_task_board_remote_claim_io_authority(
                &claim,
                HOST,
                "2026-07-19T10:00:05Z",
            )
            .await
            .expect("claim exact remote claim I/O authority")
            .expect("claim remains eligible");
        let request = status_request(&fixture.request, &accepted);
        // A raw terminal status can no longer drive an active assignment (F3), so the exact-L1
        // lease invariant is exercised by the legitimate promoting path: a lost-claim running
        // status that must reconstruct the claim receipt carries the exact accepted lease.
        let mut response = running_status(&request, &accepted);
        if mismatch == "missing" {
            response.lease = None;
        } else {
            response.lease.as_mut().expect("status lease").lease_id = "wrong-lease".into();
        }
        response.status_sha256.clear();
        let response = response.seal().expect("reseal mismatched status");
        assert!(
            fixture
                .db
                .claim_task_board_remote_status_io_authority(&request, HOST)
                .await
                .expect("handoff pending claim trust to status")
        );
        let sequence = fixture
            .db
            .current_change_sequence()
            .await
            .expect("sequence after status authority");
        let outcome = fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await;
        if mismatch == "missing" {
            assert!(
                outcome
                    .expect_err("missing L1 lease must fail closed")
                    .to_string()
                    .contains("omitted its exact lease")
            );
        } else {
            assert!(matches!(
                outcome.expect("wrong L1 lease is stale"),
                TaskBoardRemoteMutationOutcome::Stale(_)
            ));
        }
        let assignment = fixture
            .db
            .task_board_remote_assignment(&accepted.assignment_id)
            .await
            .expect("load unchanged assignment")
            .expect("assignment");
        assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Offered);
        assert!(assignment.claim_receipt.is_none());
        assert_eq!(
            load_execution(&fixture).await.transition.execution_state,
            TaskBoardExecutionState::Starting
        );
        assert_eq!(
            fixture
                .db
                .current_change_sequence()
                .await
                .expect("unchanged sequence"),
            sequence
        );
    }
}

async fn running_controller() -> (
    ControllerFixture,
    RemoteStatusRequest,
    super::TaskBoardRemoteAssignmentRecord,
) {
    let fixture = controller_fixture(1).await;
    running_controller_from(fixture).await
}

async fn running_controller_from(
    fixture: ControllerFixture,
) -> (
    ControllerFixture,
    RemoteStatusRequest,
    super::TaskBoardRemoteAssignmentRecord,
) {
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let request = status_request(&fixture.request, &claimed);
    let response = running_status(&request, &claimed);
    fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect("record remote running evidence");
    let running = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load running assignment")
        .expect("running assignment");
    (fixture, request, running)
}

async fn load_execution(
    fixture: &ControllerFixture,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load execution")
        .expect("execution")
}

fn failure_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    failure_class: TaskBoardFailureClass,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: current_lease(request, assignment),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some(STARTED_AT.into()),
        workspace_ref: Some("workspace-1".into()),
        error_code: Some("executor_failed".into()),
        failure_class: Some(failure_class),
        observed_at: "2026-07-19T10:00:30Z".into(),
    }
    .seal()
    .expect("seal failed status")
}

fn superseded_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    claimed: bool,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Superseded,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: current_lease(request, assignment),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: claimed.then(|| CLAIMED_AT.into()),
        started_at: claimed.then(|| STARTED_AT.into()),
        workspace_ref: claimed.then(|| "workspace-1".into()),
        error_code: Some("executor_superseded".into()),
        failure_class: None,
        observed_at: "2026-07-19T10:00:30Z".into(),
    }
    .seal()
    .expect("seal superseded status")
}

fn ambiguous_terminal_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    state: RemoteAssignmentWireState,
) -> RemoteStatusResponse {
    let mut response = failure_status(request, assignment, TaskBoardFailureClass::Permanent);
    response.state = state;
    response.failure_class = None;
    response.status_sha256.clear();
    response.seal().expect("seal provisional terminal status")
}

fn current_lease(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> Option<RemoteLease> {
    Some(RemoteLease {
        lease_id: request.lease_id.clone(),
        expires_at: assignment.lease_expires_at.clone().expect("lease expiry"),
    })
}
