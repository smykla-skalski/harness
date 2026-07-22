use sqlx::{Executor, query, query_as};

use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::accept_controller;
use super::remote_assignment_test_support::{
    CLAIMED_AT, ControllerFixture, HOST, NOW, controller_fixture,
};
use super::workflow_execution_rows::{execution_json, label};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteSettledRequest,
    RemoteSettledResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::task_board_remote_transport::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};
use crate::task_board::{TaskBoardExecutionState, TaskBoardWorkflowExecutionCas};

const SETTLED_AT: &str = "2026-07-19T10:00:20Z";
const CLEANED_AT: &str = "2026-07-19T10:00:30Z";
const CHANGED_PARENT_AT: &str = "2026-07-19T10:00:21Z";
const HANDOFF_AT: &str = "2026-07-19T10:00:19Z";

#[path = "remote_assignment_cleanup_handoff_tests/corruption.rs"]
mod corruption;

#[tokio::test]
async fn exact_cleanup_handoff_releases_a_detached_terminal_generation_once() {
    let fixture = controller_fixture(1).await;
    let cancelled = cancel_controller_assignment(&fixture).await;
    let settlement = settle_controller_assignment(&fixture, &cancelled).await;
    assert!(
        fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                &cancelled.assignment_id,
                cancelled.fencing_epoch,
            )
            .await
            .expect("terminal projection grants settlement authority")
    );

    let cleanup = RemoteCleanupObservationRequest::for_settlement(&settlement)
        .expect("seal cleanup observation request");
    let response = RemoteCleanupObservationResponse::for_completed(&cleanup, CLEANED_AT.into())
        .expect("seal cleanup observation response");
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load cleanup host trust");
    assert!(
        fixture
            .db
            .claim_task_board_remote_cleanup_observation_fenced(&cleanup, HOST, &trust)
            .await
            .expect("claim cleanup observation")
            .is_none()
    );
    query(
        "UPDATE task_board_workflow_executions
         SET updated_at = ?2, completed_at = ?2
         WHERE execution_id = ?1",
    )
    .bind(&fixture.execution.execution_id)
    .bind(CHANGED_PARENT_AT)
    .execute(fixture.db.pool())
    .await
    .expect("advance parent after cleanup authority claim");

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_cleanup_observation(&cleanup, &response, HOST, &trust)
            .await
            .expect("adopt cleanup across parent advance"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.cleanup_completed_at.as_deref() == Some(CLEANED_AT)
    ));
    assert_terminal_projection_handoff(&fixture).await;
    assert_cleanup_replay_is_noop(&fixture, &cleanup, &response, &trust).await;
}

#[tokio::test]
async fn terminal_cleanup_handoff_survives_parent_deletion_after_exact_settlement() {
    let fixture = controller_fixture(1).await;
    let superseded = superseded_detached_controller_assignment(&fixture).await;
    record_pending_cleanup_handoff(&fixture, &superseded).await;
    let settlement = settle_controller_assignment(&fixture, &superseded).await;
    let cleanup = RemoteCleanupObservationRequest::for_settlement(&settlement)
        .expect("seal superseded cleanup request");
    let response = RemoteCleanupObservationResponse::for_completed(&cleanup, CLEANED_AT.into())
        .expect("seal superseded cleanup response");
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load superseded cleanup trust");
    assert!(
        fixture
            .db
            .claim_task_board_remote_cleanup_observation_fenced(&cleanup, HOST, &trust)
            .await
            .expect("claim cleanup before parent deletion")
            .is_none()
    );
    query("DELETE FROM task_board_workflow_executions WHERE execution_id = ?1")
        .bind(&fixture.execution.execution_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete parent after exact cleanup claim");

    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_cleanup_observation(&cleanup, &response, HOST, &trust)
            .await
            .expect("adopt cleanup after parent deletion"),
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.cleanup_completed_at.as_deref() == Some(CLEANED_AT)
    ));
    assert_terminal_cleanup_handoff(&fixture).await;
    assert_cleanup_replay_is_noop(&fixture, &cleanup, &response, &trust).await;
}

async fn record_pending_cleanup_handoff(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) {
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load detached cleanup parent")
        .expect("detached cleanup parent exists");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_terminal_cleanup_handoff(
                assignment,
                &TaskBoardWorkflowExecutionCas::from(&parent),
                HANDOFF_AT,
            )
            .await
            .expect("record pending cleanup handoff"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_terminal_cleanup_handoff(
                assignment,
                &TaskBoardWorkflowExecutionCas::from(&parent),
                HANDOFF_AT,
            )
            .await
            .expect("replay pending cleanup handoff"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    assert!(
        fixture
            .db
            .task_board_remote_assignment_has_settlement_handoff(
                &assignment.assignment_id,
                assignment.fencing_epoch,
            )
            .await
            .expect("load pending settlement handoff")
    );
    assert_pending_cleanup_handoff(fixture).await;
}

async fn cancel_controller_assignment(
    fixture: &ControllerFixture,
) -> super::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_controller(fixture).await;
    let request = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "terminal cleanup handoff test".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cleanup cancel request");
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
    .expect("seal cleanup cancel response");
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:02Z")
        .await
        .expect("claim cleanup cancel authority")
        .expect("cleanup cancel remains active");
    match fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:11Z",
        )
        .await
        .expect("persist cleanup cancel response")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected cancelled controller assignment, got {other:?}"),
    }
}

async fn superseded_detached_controller_assignment(
    fixture: &ControllerFixture,
) -> super::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_controller(fixture).await;
    restore_parent_to_targetless_preparing(fixture).await;
    match fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "detached terminal cleanup handoff test",
            HANDOFF_AT,
        )
        .await
        .expect("supersede detached accepted assignment")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => {
            assert_eq!(record.assignment_id, accepted.assignment_id);
            record
        }
        other => panic!("expected superseded controller assignment, got {other:?}"),
    }
}

async fn settle_controller_assignment(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    let request = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("terminal lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state: terminal_wire_state(assignment),
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal controller settlement request");
    let response = RemoteSettledResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        settlement_request_sha256: request.request_sha256.clone(),
        settled_at: SETTLED_AT.into(),
    };
    assert!(
        fixture
            .db
            .claim_task_board_remote_settlement_io_authority(
                &request,
                HOST,
                "2026-07-19T10:00:12Z",
            )
            .await
            .expect("claim controller settlement authority")
            .is_none()
    );
    fixture
        .db
        .record_task_board_remote_settlement_response(&request, &response, HOST)
        .await
        .expect("persist controller settlement receipt");
    request
}

async fn restore_parent_to_targetless_preparing(fixture: &ControllerFixture) {
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
    .bind(
        label(
            TaskBoardExecutionState::Preparing,
            "workflow execution state",
        )
        .expect("encode restored parent state"),
    )
    .bind(diagnostics)
    .bind(ownership)
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("restore detached parent");
    query(
        "UPDATE task_board_execution_attempts
         SET state = 'preparing', failure_class = NULL, available_at = NULL,
             error = NULL, artifact_json = NULL, completed_at = NULL, updated_at = ?4
         WHERE execution_id = ?1 AND action_key = ?2 AND attempt = ?3",
    )
    .bind(&fixture.attempt.execution_id)
    .bind(&fixture.attempt.action_key)
    .bind(i64::from(fixture.attempt.attempt))
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("restore detached attempt");
}

async fn assert_pending_cleanup_handoff(fixture: &ControllerFixture) {
    let row = query_as::<_, (Option<String>, String, String)>(
        "SELECT cleanup_completed_at, controller_handoff_kind, controller_handoff_at
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load pending cleanup evidence");
    assert_eq!(row, (None, "terminal_cleanup".into(), HANDOFF_AT.into()));
}

fn terminal_wire_state(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteAssignmentWireState {
    match assignment.state {
        crate::task_board::TaskBoardRemoteAssignmentState::Cancelled => {
            RemoteAssignmentWireState::Cancelled
        }
        crate::task_board::TaskBoardRemoteAssignmentState::Superseded => {
            RemoteAssignmentWireState::Superseded
        }
        _ => panic!("test only settles cancelled or superseded assignments"),
    }
}

async fn assert_terminal_projection_handoff(fixture: &ControllerFixture) {
    let row = query_as::<_, (String, String, String, String)>(
        "SELECT controller_handoff_kind, controller_handoff_execution_sha256,
                controller_handoff_at, cleanup_completed_at
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load terminal projection handoff");
    assert_eq!(row.0, "terminal_projection");
    assert_eq!(row.1.len(), 64);
    assert!(!row.2.is_empty());
    assert_eq!(row.3, CLEANED_AT);
}

async fn assert_terminal_cleanup_handoff(fixture: &ControllerFixture) {
    let row = query_as::<_, (String, String, String, String)>(
        "SELECT controller_handoff_kind, controller_handoff_execution_sha256,
                controller_handoff_at, cleanup_completed_at
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load terminal cleanup handoff");
    assert_eq!(row.0, "terminal_cleanup");
    assert_eq!(row.1.len(), 64);
    assert_eq!(row.2, HANDOFF_AT);
    assert_eq!(row.3, CLEANED_AT);
}

async fn assert_cleanup_replay_is_noop(
    fixture: &ControllerFixture,
    request: &RemoteCleanupObservationRequest,
    response: &RemoteCleanupObservationResponse,
    trust: &crate::daemon::db::TaskBoardRemoteHostTrustFence,
) {
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load cleanup replay sequence");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_cleanup_observation(request, response, HOST, trust)
            .await
            .expect("replay exact cleanup response"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
    assert_eq!(
        fixture
            .db
            .current_change_sequence()
            .await
            .expect("reload cleanup replay sequence"),
        sequence
    );
}

async fn corrupt_parent_json(fixture: &ControllerFixture) {
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire undecodable-parent corruption connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow explicit undecodable-parent corruption");
    query(
        "UPDATE task_board_workflow_executions SET diagnostics_json = '{' WHERE execution_id = ?1",
    )
    .bind(&fixture.execution.execution_id)
    .execute(&mut *connection)
    .await
    .expect("persist deliberately undecodable parent row");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict undecodable-parent checks");
}

async fn clear_handoff_for_explicit_corruption(fixture: &ControllerFixture, assignment_id: &str) {
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire no-handoff corruption connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow explicit no-handoff corruption");
    query(
        "UPDATE task_board_remote_assignments SET controller_handoff_kind = NULL,
         controller_handoff_execution_sha256 = NULL,
         controller_handoff_successor_assignment_id = NULL,
         controller_handoff_successor_fencing_epoch = NULL,
         controller_handoff_at = NULL WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .execute(&mut *connection)
    .await
    .expect("clear exact terminal handoff");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict no-handoff checks");
}
