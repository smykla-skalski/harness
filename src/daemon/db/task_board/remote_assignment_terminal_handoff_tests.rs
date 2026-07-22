use sqlx::{query, query_as};

use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::{
    accept_controller, claim_controller, running_status, status_request,
};
use super::remote_assignment_test_support::{
    AFTER_EXPIRY, CLAIMED_AT, ControllerFixture, HOST, NOW, STARTED_AT, controller_fixture,
};
use super::workflow_execution_rows::{execution_json, label};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteSettledRequest,
    RemoteStatusRequest, RemoteStatusResponse, RemoteTypedResult,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardLocalAttemptResult, TaskBoardRemoteAssignmentState, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardStatus, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowStatus, TaskBoardPhaseVerdict,
};

const HANDOFF_AT: &str = "2026-07-19T10:00:19Z";

#[path = "remote_assignment_terminal_handoff_tests/corruption.rs"]
mod corruption;

#[tokio::test]
async fn detached_completed_or_failed_cannot_record_terminal_cleanup_or_settlement_authority() {
    for state in [
        TaskBoardRemoteAssignmentState::Completed,
        TaskBoardRemoteAssignmentState::Failed,
    ] {
        let fixture = controller_fixture(1).await;
        let assignment = detached_terminal_assignment(&fixture, state).await;
        restore_parent_to_targetless_preparing(&fixture).await;
        let parent = load_parent(&fixture).await;
        let sequence = fixture
            .db
            .current_change_sequence()
            .await
            .expect("load rejected handoff sequence");

        let error = fixture
            .db
            .record_task_board_remote_terminal_cleanup_handoff(
                &assignment,
                &TaskBoardWorkflowExecutionCas::from(&parent),
                HANDOFF_AT,
            )
            .await
            .expect_err("detached result terminal cannot bypass adoption");
        assert!(error.to_string().contains("detached terminal generation"));
        assert_eq!(
            fixture
                .db
                .current_change_sequence()
                .await
                .expect("reload rejected handoff sequence"),
            sequence
        );
        assert!(!fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("reject settlement handoff"));
        let error = fixture
            .db
            .claim_task_board_remote_settlement_io_authority(
                &settlement_request(&fixture, &assignment),
                HOST,
                "2026-07-19T10:00:12Z",
            )
            .await
            .expect_err("reject settlement I/O authority without adoption");
        assert!(error.to_string().contains("durable controller handoff"));
        assert_no_cleanup_authority(&fixture, &assignment).await;
    }
}

#[tokio::test]
async fn exact_detached_superseded_cleanup_handoff_replays() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    restore_parent_to_targetless_preparing(&fixture).await;
    let assignment = match fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "detached terminal cleanup",
            HANDOFF_AT,
        )
        .await
        .expect("supersede detached offered assignment")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected superseded terminal fixture, got {other:?}"),
    };
    assert_eq!(assignment.assignment_id, accepted.assignment_id);
    let parent = load_parent(&fixture).await;

    assert!(matches!(
        record_cleanup_handoff(&fixture, &assignment, &parent).await,
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    assert!(matches!(
        record_cleanup_handoff(&fixture, &assignment, &parent).await,
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
}

#[tokio::test]
async fn recovered_unknown_definitive_evidence_handoff_is_exact_and_replayable() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let running_request = status_request(&fixture.request, &claimed);
    fixture
        .db
        .record_task_board_remote_assignment_status(
            &running_request,
            &running_status(&running_request, &claimed),
            HOST,
        )
        .await
        .expect("record running status");
    set_item_to_active_remote_execution(&fixture).await;
    let recovery = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover unknown assignment");
    assert!(recovery.failures.is_empty(), "{recovery:?}");
    assert_eq!(recovery.recovered.len(), 1, "{recovery:?}");
    let unknown = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load unknown assignment")
        .expect("unknown assignment exists");
    let request = status_request(&fixture.request, &unknown);
    let response = failed_status(&request, &unknown);

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("record definitive evidence-only failure"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Failed
    ));
    assert_unknown_terminal_projection(&fixture).await;
    let assignment = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("reload definitive assignment")
        .expect("definitive assignment exists");
    assert!(fixture
        .db
        .task_board_remote_assignment_has_settlement_handoff(
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await
        .expect("accept exact evidence-only settlement handoff"));
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_status(&request, &response, HOST)
            .await
            .expect("replay definitive evidence-only failure"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
}

async fn set_item_to_active_remote_execution(fixture: &ControllerFixture) {
    fixture
        .db
        .update_task_board_item(&fixture.execution.item_id, |item| {
            item.status = TaskBoardStatus::InProgress;
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            item.workflow.execution_id = Some(fixture.execution.execution_id.clone());
            Ok(true)
        })
        .await
        .expect("attach recovered fixture item to active workflow")
        .expect("active workflow item changes");
}

#[tokio::test]
async fn result_adopted_handoff_is_exact_and_replayable() {
    let fixture = controller_fixture(1).await;
    let assignment = detached_terminal_assignment(&fixture, TaskBoardRemoteAssignmentState::Failed).await;
    let parent = load_parent(&fixture).await;

    assert!(matches!(
        fixture
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&parent),
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("adopt exact failed remote result"),
        super::TaskBoardRemoteResultAdoptionOutcome::Updated(_)
    ));
    assert!(fixture
        .db
        .task_board_remote_assignment_has_settlement_handoff(
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await
        .expect("load result-adopted settlement handoff"));
    assert!(matches!(
        fixture
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&parent),
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("replay result-adopted handoff"),
        super::TaskBoardRemoteResultAdoptionOutcome::Replayed(_)
    ));
}

async fn record_cleanup_handoff(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
) -> TaskBoardRemoteMutationOutcome {
    fixture
        .db
        .record_task_board_remote_terminal_cleanup_handoff(
            assignment,
            &TaskBoardWorkflowExecutionCas::from(parent),
            HANDOFF_AT,
        )
        .await
        .expect("record exact terminal cleanup handoff")
}

pub(crate) async fn detached_terminal_assignment(
    fixture: &ControllerFixture,
    state: TaskBoardRemoteAssignmentState,
) -> super::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_controller(fixture).await;
    let claimed = claim_controller(fixture, &accepted).await;
    let running_request = status_request(&fixture.request, &claimed);
    let running = fixture
        .db
        .record_task_board_remote_assignment_status(
            &running_request,
            &running_status(&running_request, &claimed),
            HOST,
        )
        .await
        .expect("record running terminal fixture");
    let running = match running {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected running terminal fixture, got {other:?}"),
    };
    let request = status_request(&fixture.request, &running);
    let response = terminal_status(&fixture.request, &running, state);
    let terminal = fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect("record terminal fixture through status persistence");
    match terminal {
        TaskBoardRemoteMutationOutcome::Updated(record) if record.state == state => record,
        other => panic!("expected {state:?} terminal fixture, got {other:?}"),
    }
}

fn terminal_status(
    request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    state: TaskBoardRemoteAssignmentState,
) -> RemoteStatusResponse {
    let (wire_state, result, error_code, failure_class) = match state {
        TaskBoardRemoteAssignmentState::Completed => (
            RemoteAssignmentWireState::Completed,
            Some(
                RemoteTypedResult::seal(
                    TaskBoardLocalAttemptResult {
                        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
                        execution_id: request.binding.execution_id.clone(),
                        action_key: request.binding.action_key.clone(),
                        attempt: request.binding.attempt,
                        idempotency_key: request.binding.idempotency_key.clone(),
                        exact_head_revision: "1111111111111111111111111111111111111111".into(),
                        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
                            profile_id: "reviewer".into(),
                            result: TaskBoardReviewResult {
                                verdict: TaskBoardPhaseVerdict::Pass,
                                head_revision: "1111111111111111111111111111111111111111".into(),
                                summary: "review passed".into(),
                                findings: Vec::new(),
                            },
                        }),
                    },
                    request.request_sha256.clone(),
                )
                .expect("seal completed terminal result"),
            ),
            None,
            None,
        ),
        TaskBoardRemoteAssignmentState::Failed => (
            RemoteAssignmentWireState::Failed,
            None,
            Some("executor_failed".into()),
            Some(TaskBoardFailureClass::Permanent),
        ),
        _ => panic!("test only builds completed or failed terminal status"),
    };
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: wire_state,
        offer_request_sha256: request.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: assignment.lease_id.clone().expect("terminal lease"),
            expires_at: assignment.lease_expires_at.clone().expect("terminal lease expiry"),
        }),
        result,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some(STARTED_AT.into()),
        workspace_ref: Some("workspace-1".into()),
        error_code,
        failure_class,
        observed_at: "2026-07-19T10:00:40Z".into(),
    }
    .seal()
    .expect("seal terminal status")
}

pub(crate) async fn restore_parent_to_targetless_preparing(fixture: &ControllerFixture) {
    let mut restored = fixture.execution.clone();
    restored.transition.execution_state = TaskBoardExecutionState::Preparing;
    let (_, _, diagnostics, ownership) = execution_json(&restored).expect("encode parent restore");
    query(
        "UPDATE task_board_workflow_executions
         SET state = ?2, diagnostics_json = ?3, host_id = NULL, fencing_epoch = 0,
             resource_ownership_json = ?4, available_at = NULL, blocked_reason = NULL,
             completed_at = NULL, updated_at = ?5
         WHERE execution_id = ?1",
    )
    .bind(&restored.execution_id)
    .bind(label(TaskBoardExecutionState::Preparing, "workflow execution state").expect("state"))
    .bind(diagnostics)
    .bind(ownership)
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("restore detached parent");
}

async fn load_parent(
    fixture: &ControllerFixture,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load terminal parent")
        .expect("terminal parent exists")
}

fn settlement_request(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    let terminal_state = match assignment.state {
        TaskBoardRemoteAssignmentState::Completed => RemoteAssignmentWireState::Completed,
        TaskBoardRemoteAssignmentState::Failed => RemoteAssignmentWireState::Failed,
        _ => panic!("test only builds requests for rejected result terminals"),
    };
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("terminal lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state,
        result_sha256: assignment.result_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal terminal settlement request")
}

async fn assert_no_cleanup_authority(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) {
    let row = query_as::<_, (Option<String>, Option<String>, Option<String>)>(
        "SELECT controller_handoff_kind, cleanup_settlement_request_sha256, cleanup_completed_at
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&assignment.assignment_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load rejected cleanup authority");
    assert_eq!(row, (None, None, None));
}

async fn assert_unknown_terminal_projection(fixture: &ControllerFixture) {
    let parent = load_parent(fixture).await;
    assert_eq!(parent.transition.execution_state, TaskBoardExecutionState::HumanRequired);
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Unknown);
    let item = fixture
        .db
        .task_board_item(&parent.item_id)
        .await
        .expect("load recovered unknown item");
    assert_eq!(item.status, TaskBoardStatus::HumanRequired);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Paused);
    assert_eq!(item.workflow.execution_id.as_deref(), Some(parent.execution_id.as_str()));
}

fn failed_status(
    request: &RemoteStatusRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: request.offer_request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: request.lease_id.clone(),
            expires_at: assignment.lease_expires_at.clone().expect("terminal lease expiry"),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: Some(STARTED_AT.into()),
        workspace_ref: Some("workspace-1".into()),
        error_code: Some("executor_failed".into()),
        failure_class: Some(TaskBoardFailureClass::Permanent),
        observed_at: "2026-07-19T10:02:10Z".into(),
    }
    .seal()
    .expect("seal definitive evidence-only failure")
}
