use super::remote_assignment_source::source_binding_matches;
use super::remote_assignment_test_support::*;
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferDisposition, RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionState,
    TaskBoardPullRequestHeadIdentity, TaskBoardPullRequestIdentity, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowKind,
};

#[tokio::test]
async fn controller_offer_atomically_binds_and_exact_replay_is_a_noop() {
    let fixture = controller_fixture(1).await;

    assert_eq!(
        fixture.request.launch.persona.as_deref(),
        Some("security-reviewer")
    );
    assert_eq!(fixture.request.launch.model.as_deref(), Some("gpt-5.4"));
    assert_eq!(fixture.request.launch.effort.as_deref(), Some("high"));
    assert!(
        fixture
            .request
            .launch
            .capabilities
            .contains(&"task-board:tag:security".to_string())
    );
    assert!(
        !fixture
            .request
            .launch
            .prompt
            .contains("/tmp/controller-context-only")
    );
    assert!(
        fixture
            .request
            .launch
            .prompt
            .contains("isolated executor checkout")
    );

    let created = offer_controller(&fixture).await;
    assert!(matches!(
        created,
        TaskBoardRemoteOfferOutcome::Created(record)
            if record.lease_expires_at.as_deref() == Some(LEASE_EXPIRES)
    ));
    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Starting
    );
    assert_eq!(execution.ownership.host_id.as_deref(), Some(HOST));
    assert_eq!(execution.ownership.fencing_epoch, 1);
    assert_eq!(
        target(&execution, TASK_BOARD_EXECUTION_TARGET_RESOURCE),
        "remote:assignment-controller-1"
    );
    assert_eq!(
        target(&execution, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE),
        "review:reviewer"
    );
    assert_eq!(
        target(&execution, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE),
        "1"
    );
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Starting);
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");

    assert!(matches!(
        offer_controller(&fixture).await,
        TaskBoardRemoteOfferOutcome::Replayed(_)
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
async fn tampered_launch_contract_is_rejected_before_remote_persistence() {
    let fixture = controller_fixture(1).await;
    for mutate in [
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.launch.persona = Some("different-reviewer".into());
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.launch.model = Some("different-model".into());
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.launch.effort = Some("low".into());
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request
                .launch
                .capabilities
                .push("unexpected-capability".into());
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.launch.board_item_id = "other-item".into();
        },
    ] {
        let mut request = fixture.request.clone();
        mutate(&mut request);
        request.request_sha256.clear();
        let request = request.seal().expect("seal tampered launch");
        let error = fixture
            .db
            .offer_task_board_remote_assignment(
                &crate::task_board::TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &crate::task_board::TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                &request,
                HOST,
                crate::daemon::db::TaskBoardRemoteOfferWindow::new(NOW, LEASE_EXPIRES, DEADLINE),
            )
            .await
            .expect_err("tampered launch must fail before offer persistence");
        assert!(error.to_string().contains("frozen execution"));
        assert!(
            fixture
                .db
                .task_board_remote_assignment(&request.binding.assignment_id)
                .await
                .expect("load assignment")
                .is_none()
        );
        let execution = load_execution(&fixture).await;
        assert_eq!(
            execution.transition.execution_state,
            TaskBoardExecutionState::Preparing
        );
        assert_eq!(execution.ownership.host_id, None);
    }
}

#[tokio::test]
async fn wrong_base_or_head_is_rejected_before_assignment_or_target_mutation() {
    let fixture = controller_fixture(1).await;
    for mutate in [
        // Canonical but wrong evidence reaches the frozen-execution check rather than wire validation.
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.binding.base_revision = "2222222222222222222222222222222222222222".into();
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.binding.expected_head_revision =
                Some("2222222222222222222222222222222222222222".into());
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            request.binding.repository = "example/other".into();
            let crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::Repository {
                repository,
                ..
            } = &mut request.source
            else {
                unreachable!("controller fixture uses a repository source")
            };
            *repository = "example/other".into();
        },
        |request: &mut crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest| {
            let crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::Repository {
                revision,
                ..
            } = &mut request.source
            else {
                unreachable!("controller fixture uses a repository source")
            };
            *revision = "2222222222222222222222222222222222222222".into();
        },
    ] {
        let mut request = fixture.request.clone();
        mutate(&mut request);
        request.request_sha256.clear();
        request = request.seal().expect("reseal invalid provenance request");
        let error = fixture
            .db
            .offer_task_board_remote_assignment(
                &crate::task_board::TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &crate::task_board::TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                &request,
                HOST,
                crate::daemon::db::TaskBoardRemoteOfferWindow::new(NOW, LEASE_EXPIRES, DEADLINE),
            )
            .await
            .expect_err("wrong revision evidence must fail");
        assert!(error.to_string().contains("frozen execution"));
        assert!(
            fixture
                .db
                .task_board_remote_assignment(&request.binding.assignment_id)
                .await
                .expect("load assignment")
                .is_none()
        );
        let execution = load_execution(&fixture).await;
        assert_eq!(
            execution.transition.execution_state,
            TaskBoardExecutionState::Preparing
        );
    }
}

#[tokio::test]
async fn frozen_pull_request_head_binds_fork_repository_branch_ref_and_revision() {
    let fixture = controller_fixture(1).await;
    let mut parent = fixture.execution.clone();
    parent.snapshot.workflow_kind = TaskBoardWorkflowKind::PrReview;
    parent.transition.workflow_kind = TaskBoardWorkflowKind::PrReview;
    parent.transition.pull_request = Some(TaskBoardPullRequestIdentity {
        repository: REPOSITORY.into(),
        number: 17,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: "contributor/harness".into(),
            branch: "feature/fix".into(),
            revision: SOURCE_REVISION.into(),
        }),
    });
    let mut request = fixture.request.clone();
    request.binding.workflow_kind = TaskBoardWorkflowKind::PrReview;
    // The binding repository tracks the fork source the offer freezes.
    request.binding.repository = "contributor/harness".into();
    request.source =
        crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::repository_branch(
            "contributor/harness",
            "feature/fix",
            SOURCE_REVISION,
        );
    request.request_sha256.clear();
    request = request.seal().expect("seal frozen fork source");
    request.validate().expect("validate frozen fork source");
    assert!(source_binding_matches(&request, &parent));

    for changed in [
        crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::repository_branch(
            REPOSITORY,
            "feature/fix",
            SOURCE_REVISION,
        ),
        crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::repository_branch(
            "contributor/harness",
            "feature/other",
            SOURCE_REVISION,
        ),
        crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::repository_branch(
            "contributor/harness",
            "feature/fix",
            "2222222222222222222222222222222222222222",
        ),
    ] {
        request.source = changed;
        assert!(!source_binding_matches(&request, &parent));
    }
}

#[tokio::test]
async fn rejected_offer_binds_one_local_start_and_never_becomes_remote_eligible_again() {
    let fixture = controller_fixture(1).await;
    let TaskBoardRemoteOfferOutcome::Created(assignment) = offer_controller(&fixture).await else {
        panic!("controller offer was not created");
    };
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim offer I/O authority")
        .expect("offer remains active");
    let rejected = rejected_response(&fixture.request, "capacity_changed");

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_offer_response(&rejected, HOST, CLAIMED_AT)
            .await
            .expect("record rejection"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Starting
    );
    assert_eq!(execution.ownership.host_id, None);
    assert_eq!(execution.ownership.fencing_epoch, assignment.fencing_epoch);
    assert_eq!(
        target(&execution, TASK_BOARD_EXECUTION_TARGET_RESOURCE),
        "local"
    );
    assert_eq!(execution.attempts.len(), 2);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    assert_eq!(execution.attempts[1].state, TaskBoardAttemptState::Starting);
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_offer_response(&rejected, HOST, CLAIMED_AT)
            .await
            .expect("replay rejection"),
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
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment(&assignment.assignment_id)
            .await
            .expect("load assignment")
            .expect("assignment")
            .state,
        TaskBoardRemoteAssignmentState::Superseded
    );
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

fn target<'a>(
    execution: &'a crate::task_board::TaskBoardWorkflowExecutionRecord,
    key: &str,
) -> &'a str {
    execution
        .ownership
        .resources
        .get(key)
        .expect("target evidence")
}

fn rejected_response(
    request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    reason: &str,
) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Rejected,
        lease: None,
        rejection_code: Some(reason.into()),
    }
}
