use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_generation_tests::{
    accept_controller, claim_controller, running_status, status_request,
};
use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_test_support::*;
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, claim_controller_operation_trust_in_tx,
};
use super::workflow_execution_attempts::update_attempt_in_tx;
use super::workflow_executions::update_execution_in_tx;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteClaimResponse, RemoteLease, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, validate_task_board_attempt_update,
    validate_task_board_workflow_execution,
};

const DIVERGED_AT: &str = "2026-07-19T10:00:30Z";

#[tokio::test]
async fn late_claim_response_recovers_from_the_persisted_state_with_or_without_authority() {
    for preclaim_authority in [false, true] {
        assert_late_claim_recovery(preclaim_authority).await;
    }
}

#[tokio::test]
async fn non_remote_parent_divergence_supersedes_only_the_exact_assignment() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let diverged = bind_parent_locally(&fixture).await;

    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover diverged controller assignment");

    assert!(recovered.failures.is_empty());
    assert_eq!(recovered.recovered.len(), 1);
    assert_eq!(recovered.recovered[0].assignment_id, claimed.assignment_id);
    assert_eq!(
        recovered.recovered[0].state,
        TaskBoardRemoteAssignmentState::Superseded
    );
    assert_eq!(load_execution(&fixture).await, diverged);
    let replay = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("replay diverged recovery");
    assert!(replay.recovered.is_empty());
    assert!(replay.failures.is_empty());
}

#[tokio::test]
async fn terminal_parent_supersedes_the_retained_remote_generation() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let terminal = terminalize_parent_out_of_band(&fixture).await;

    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("recover terminal-parent assignment");

    assert!(recovered.failures.is_empty());
    assert!(matches!(
        recovered.recovered.as_slice(),
        [record]
            if record.assignment_id == claimed.assignment_id
                && record.state == TaskBoardRemoteAssignmentState::Superseded
    ));
    assert_eq!(load_execution(&fixture).await, terminal);
}

#[tokio::test]
async fn active_assignment_divergence_and_terminal_parent_free_capacity() {
    for assignment_state in [
        TaskBoardRemoteAssignmentState::Claimed,
        TaskBoardRemoteAssignmentState::Started,
        TaskBoardRemoteAssignmentState::Running,
    ] {
        for terminal_parent in [false, true] {
            let fixture = controller_fixture(1).await;
            let active = active_assignment(&fixture, assignment_state).await;
            let preserved_parent = if terminal_parent {
                terminalize_parent_out_of_band(&fixture).await
            } else {
                bind_parent_locally(&fixture).await
            };
            let preserved_item = load_item_snapshot(&fixture).await;

            let recovered = fixture
                .db
                .recover_task_board_remote_assignments(AFTER_EXPIRY)
                .await
                .expect("recover detached active assignment");

            assert!(recovered.failures.is_empty());
            assert!(matches!(
                recovered.recovered.as_slice(),
                [record]
                    if record.assignment_id == active.assignment_id
                        && record.state == TaskBoardRemoteAssignmentState::Superseded
            ));
            assert_eq!(active_controller_assignments(&fixture).await, 0);
            assert_eq!(load_execution(&fixture).await, preserved_parent);
            assert_eq!(load_item_snapshot(&fixture).await, preserved_item);
            let replay = fixture
                .db
                .recover_task_board_remote_assignments(AFTER_EXPIRY)
                .await
                .expect("replay detached active recovery");
            assert!(replay.recovered.is_empty());
            assert!(replay.failures.is_empty());
            assert_eq!(active_controller_assignments(&fixture).await, 0);
            assert_eq!(load_execution(&fixture).await, preserved_parent);
            assert_eq!(load_item_snapshot(&fixture).await, preserved_item);
        }
    }
}

#[tokio::test]
async fn failed_detached_supersede_rolls_back_assignment_and_parent() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let claimed = claim_controller(&fixture, &accepted).await;
    let diverged = bind_parent_locally(&fixture).await;
    install_supersede_failure(&fixture).await;

    let batch = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("isolate failed detached recovery");

    assert!(batch.recovered.is_empty());
    assert_eq!(batch.failures.len(), 1);
    assert_eq!(batch.failures[0].assignment_id, claimed.assignment_id);
    let retained = load_assignment(&fixture, &claimed.assignment_id).await;
    assert_eq!(retained, claimed);
    assert_eq!(load_execution(&fixture).await, diverged);
}

async fn assert_late_claim_recovery(preclaim_authority: bool) {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = claim_request(&fixture.request, &accepted);
    if preclaim_authority {
        fixture
            .db
            .claim_task_board_remote_claim_io_authority(&request, HOST, "2026-07-19T10:00:05Z")
            .await
            .expect("claim remote claim authority")
            .expect("claim remains active");
    } else {
        claim_only_operation_trust(&fixture, &request).await;
    }
    let response = claim_response(&fixture, &accepted);
    let outcome = fixture
        .db
        .record_task_board_remote_assignment_claim(&request, &response, HOST, AFTER_EXPIRY)
        .await
        .expect("retain and recover late claim response");
    assert!(matches!(
        outcome,
        TaskBoardRemoteMutationOutcome::Updated(record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.claimed_at.as_deref() == Some(CLAIMED_AT)
    ));
    let parent = load_execution(&fixture).await;
    assert_eq!(
        parent.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        parent.blocked_reason.as_deref(),
        Some("remote_assignment_outcome_unknown")
    );
    assert!(
        !parent
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
    );
}

async fn claim_only_operation_trust(
    fixture: &ControllerFixture,
    request: &crate::daemon::task_board_remote_transport::wire::RemoteClaimRequest,
) {
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("test remote claim operation trust")
        .await
        .expect("begin claim operation trust");
    let assignment = require_assignment(&mut transaction, &request.binding.assignment_id)
        .await
        .expect("load claim operation assignment");
    claim_controller_operation_trust_in_tx(
        &mut transaction,
        &assignment,
        TaskBoardRemoteOperationKind::Claim,
        &request.request_sha256,
        None,
    )
    .await
    .expect("claim exact host operation trust");
    transaction
        .commit()
        .await
        .expect("commit claim operation trust");
}

async fn active_assignment(
    fixture: &ControllerFixture,
    state: TaskBoardRemoteAssignmentState,
) -> super::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_controller(fixture).await;
    let claimed = claim_controller(fixture, &accepted).await;
    if state == TaskBoardRemoteAssignmentState::Claimed {
        return claimed;
    }
    if state == TaskBoardRemoteAssignmentState::Started {
        sqlx::query(
            "UPDATE task_board_remote_assignments
             SET state = 'started', started_at = ?2, heartbeat_at = ?2,
                 workspace_ref = 'workspace-1', updated_at = ?2
             WHERE assignment_id = ?1 AND fencing_epoch = ?3 AND state = 'claimed'",
        )
        .bind(&claimed.assignment_id)
        .bind(STARTED_AT)
        .bind(i64::try_from(claimed.fencing_epoch).expect("started fencing epoch"))
        .execute(fixture.db.pool())
        .await
        .expect("persist controller started fixture");
        let started = load_assignment(fixture, &claimed.assignment_id).await;
        assert_eq!(started.state, state);
        return started;
    }
    let request = status_request(&fixture.request, &claimed);
    let response = running_status(&request, &claimed);
    fixture
        .db
        .claim_task_board_remote_status_io_authority(&request, HOST)
        .await
        .expect("claim running status authority");
    match fixture
        .db
        .record_task_board_remote_assignment_status(&request, &response, HOST)
        .await
        .expect("record running assignment")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) if record.state == state => record,
        other => panic!("expected {state:?} assignment, got {other:?}"),
    }
}

async fn active_controller_assignments(fixture: &ControllerFixture) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_assignments
         WHERE host_id = ?1
           AND state IN ('offered', 'claimed', 'started', 'running', 'unknown')",
    )
    .bind(HOST)
    .fetch_one(fixture.db.pool())
    .await
    .expect("count active controller assignments")
}

fn claim_response(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteClaimResponse {
    RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: assignment.lease_id.clone().expect("accepted lease"),
            expires_at: assignment
                .lease_expires_at
                .clone()
                .expect("accepted lease expiry"),
        },
        claimed_at: CLAIMED_AT.into(),
    }
}

async fn bind_parent_locally(
    fixture: &ControllerFixture,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let current = load_execution(fixture).await;
    let mut local = current.clone();
    local.ownership.host_id = None;
    local
        .ownership
        .resources
        .insert(TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(), "local".into());
    local.updated_at = DIVERGED_AT.into();
    persist_parent(fixture, &current, &local, None).await;
    local
}

async fn terminalize_parent_out_of_band(
    fixture: &ControllerFixture,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let current = load_execution(fixture).await;
    let current_attempt = current.attempts[0].clone();
    let mut cancelled_attempt = current_attempt.clone();
    cancelled_attempt.state = TaskBoardAttemptState::Cancelled;
    cancelled_attempt.error = Some("external terminal path".into());
    cancelled_attempt.updated_at = DIVERGED_AT.into();
    cancelled_attempt.completed_at = Some(DIVERGED_AT.into());
    validate_task_board_attempt_update(&current_attempt, &cancelled_attempt)
        .expect("validate out-of-band terminal attempt");
    let mut terminal = current.clone();
    terminal.transition.execution_state = TaskBoardExecutionState::Cancelled;
    terminal.ownership.host_id = None;
    terminal
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_RESOURCE);
    terminal
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    terminal
        .ownership
        .resources
        .remove(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE);
    terminal.blocked_reason = None;
    terminal.updated_at = DIVERGED_AT.into();
    terminal.completed_at = Some(DIVERGED_AT.into());
    terminal.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Cancelled,
        summary: "external terminal path".into(),
        recorded_at: DIVERGED_AT.into(),
    });
    let mut combined = terminal.clone();
    combined.attempts[0] = cancelled_attempt.clone();
    validate_task_board_workflow_execution(&combined)
        .expect("validate out-of-band terminal execution");
    persist_parent(
        fixture,
        &current,
        &terminal,
        Some((&current_attempt, &cancelled_attempt)),
    )
    .await;
    combined
}

async fn persist_parent(
    fixture: &ControllerFixture,
    current: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    updated: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    attempt: Option<(
        &crate::task_board::TaskBoardExecutionAttemptRecord,
        &crate::task_board::TaskBoardExecutionAttemptRecord,
    )>,
) {
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("test non-remote parent mutation")
        .await
        .expect("begin parent mutation");
    update_execution_in_tx(
        &mut transaction,
        &TaskBoardWorkflowExecutionCas::from(current),
        updated,
    )
    .await
    .expect("persist parent mutation");
    if let Some((expected, updated)) = attempt {
        update_attempt_in_tx(
            &mut transaction,
            &TaskBoardExecutionAttemptCas::from(expected),
            updated,
        )
        .await
        .expect("persist attempt mutation");
    }
    transaction.commit().await.expect("commit parent mutation");
}

async fn install_supersede_failure(fixture: &ControllerFixture) {
    sqlx::query(
        "CREATE TRIGGER fail_detached_supersede BEFORE UPDATE OF state
         ON task_board_remote_assignments WHEN NEW.state = 'superseded'
         BEGIN SELECT RAISE(ABORT, 'fixture failure'); END",
    )
    .execute(fixture.db.pool())
    .await
    .expect("install detached supersede failure");
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

async fn load_item_snapshot(
    fixture: &ControllerFixture,
) -> (crate::task_board::TaskBoardItem, i64) {
    let snapshot = fixture
        .db
        .task_board_item_snapshot(&fixture.execution.item_id)
        .await
        .expect("load item snapshot");
    (snapshot.item, snapshot.item_revision)
}

async fn load_assignment(
    fixture: &ControllerFixture,
    assignment_id: &str,
) -> super::TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load assignment")
        .expect("assignment")
}
