use sqlx::{Executor, query};

use super::super::TaskBoardRemoteMutationOutcome;
use super::super::remote_assignment_generation_tests::accept_controller;
use super::super::remote_assignment_test_support::{
    CLAIMED_AT, ControllerFixture, HOST, controller_fixture,
};
use super::{HANDOFF_AT as TERMINAL_HANDOFF_AT, restore_parent_to_targetless_preparing};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas};

#[tokio::test]
async fn same_target_superseded_generation_cannot_record_a_cleanup_handoff() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let superseded = match fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "same target superseded corruption",
            TERMINAL_HANDOFF_AT,
        )
        .await
        .expect("supersede active target")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected superseded active target, got {other:?}"),
    };
    assert_eq!(superseded.assignment_id, accepted.assignment_id);
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load same-target parent")
        .expect("same-target parent exists");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load same-target sequence");

    let error = fixture
        .db
        .record_task_board_remote_terminal_cleanup_handoff(
            &superseded,
            &TaskBoardWorkflowExecutionCas::from(&parent),
            TERMINAL_HANDOFF_AT,
        )
        .await
        .expect_err("same-target superseded generation must not detach");

    assert!(error.to_string().contains("detached terminal generation"));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("reload same-target sequence"),
        sequence
    );
    assert_no_handoff(&fixture, &superseded.assignment_id).await;
}

#[tokio::test]
async fn same_target_cancelled_generation_without_handoff_cannot_create_cleanup_authority() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted terminal lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "same target cancelled corruption".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancelled corruption request");
    let response = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: None,
        started_at: None,
        workspace_ref: None,
        observed_at: CLAIMED_AT.into(),
    }
    .seal(&request)
    .expect("seal cancelled corruption response");
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:02Z")
        .await
        .expect("claim cancelled corruption authority")
        .expect("cancelled corruption authority remains active");
    let cancelled = match fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("persist cancelled corruption fixture")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected cancelled corruption fixture, got {other:?}"),
    };
    clear_handoff_for_explicit_corruption(&fixture, &cancelled.assignment_id).await;
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load same-target cancelled parent")
        .expect("same-target cancelled parent exists");
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load same-target cancelled sequence");

    let error = fixture
        .db
        .record_task_board_remote_terminal_cleanup_handoff(
            &cancelled,
            &TaskBoardWorkflowExecutionCas::from(&parent),
            TERMINAL_HANDOFF_AT,
        )
        .await
        .expect_err("same-target cancelled generation must not detach");

    assert!(error.to_string().contains("detached terminal generation"));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("reload same-target cancelled sequence"),
        sequence
    );
    assert_no_terminal_handoff(&fixture, &cancelled.assignment_id, cancelled.fencing_epoch).await;
}

#[tokio::test]
async fn uppercase_or_malformed_terminal_handoff_evidence_fails_closed() {
    for corruption in ["uppercase", "malformed_time"] {
        let (fixture, assignment) = detached_superseded_handoff().await;
        inject_unchecked_handoff_corruption(&fixture, &assignment.assignment_id, corruption).await;

        let result = fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await;
        if corruption == "malformed_time" {
            assert!(result.is_err(), "malformed timestamp must fail closed");
        } else {
            assert!(
                !result.expect("uppercase immutable handoff must be rejected"),
                "uppercase digest must not grant settlement authority"
            );
        }
    }
}

#[tokio::test]
async fn schema_valid_mismatched_terminal_handoff_kind_is_not_settlement_authority() {
    let fixture = controller_fixture(1).await;
    let assignment =
        super::detached_terminal_assignment(&fixture, TaskBoardRemoteAssignmentState::Failed).await;
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load failed parent")
        .expect("failed parent exists");
    fixture
        .db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await
        .expect("adopt failed terminal result");
    query(
        "UPDATE task_board_remote_assignments
         SET controller_handoff_kind = 'terminal_projection'
         WHERE assignment_id = ?1",
    )
    .bind(&assignment.assignment_id)
    .execute(fixture.db.pool())
    .await
    .expect("persist schema-valid mismatched terminal handoff kind");

    assert!(
        !fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("mismatched handoff kind must be rejected")
    );
}

async fn assert_no_handoff(fixture: &ControllerFixture, assignment_id: &str) {
    let assignment = fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load rejected cleanup assignment")
        .expect("rejected cleanup assignment exists");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Superseded);
    assert!(assignment.cleanup_completed_at.is_none());
    assert!(
        !fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("same-target rejection leaves no handoff")
    );
}

async fn assert_no_terminal_handoff(
    fixture: &ControllerFixture,
    assignment_id: &str,
    fencing_epoch: u64,
) {
    assert!(
        !fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(assignment_id, fencing_epoch)
            .await
            .expect("same-target rejection leaves no terminal handoff")
    );
}

async fn detached_superseded_handoff() -> (
    ControllerFixture,
    super::super::TaskBoardRemoteAssignmentRecord,
) {
    let fixture = controller_fixture(1).await;
    let _ = accept_controller(&fixture).await;
    restore_parent_to_targetless_preparing(&fixture).await;
    let assignment = match fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "detached terminal corruption",
            TERMINAL_HANDOFF_AT,
        )
        .await
        .expect("supersede detached generation")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected detached superseded generation, got {other:?}"),
    };
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load detached corruption parent")
        .expect("detached corruption parent exists");
    fixture
        .db
        .record_task_board_remote_terminal_cleanup_handoff(
            &assignment,
            &TaskBoardWorkflowExecutionCas::from(&parent),
            TERMINAL_HANDOFF_AT,
        )
        .await
        .expect("record exact terminal cleanup handoff");
    (fixture, assignment)
}

async fn inject_unchecked_handoff_corruption(
    fixture: &ControllerFixture,
    assignment_id: &str,
    corruption: &str,
) {
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire raw corruption connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow explicit handoff corruption");
    match corruption {
        "uppercase" => {
            query(
                "UPDATE task_board_remote_assignments
                 SET controller_handoff_execution_sha256 =
                     upper(controller_handoff_execution_sha256)
                 WHERE assignment_id = ?1",
            )
            .bind(assignment_id)
            .execute(&mut *connection)
            .await
            .expect("persist uppercase handoff digest");
        }
        "malformed_time" => {
            query(
                "UPDATE task_board_remote_assignments
                 SET controller_handoff_at = 'not-a-canonical-time'
                 WHERE assignment_id = ?1",
            )
            .bind(assignment_id)
            .execute(&mut *connection)
            .await
            .expect("persist malformed handoff time");
        }
        _ => unreachable!("fixed corruption cases"),
    }
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict handoff checks");
}

async fn clear_handoff_for_explicit_corruption(fixture: &ControllerFixture, assignment_id: &str) {
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire cancelled corruption connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow missing cancelled handoff corruption");
    query(
        "UPDATE task_board_remote_assignments SET
         controller_handoff_kind = NULL,
         controller_handoff_execution_sha256 = NULL,
         controller_handoff_successor_assignment_id = NULL,
         controller_handoff_successor_fencing_epoch = NULL,
         controller_handoff_at = NULL
         WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .execute(&mut *connection)
    .await
    .expect("persist missing cancelled handoff corruption");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict cancelled handoff checks");
}
