use sqlx::query_scalar;

use super::remote_assignment_generation_tests::{accept_controller, claim_controller};
use super::remote_assignment_test_support::*;
use super::workflow_dispatch::workflow_owner;
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteOfferRequest,
    RemoteSettledRequest, RemoteSettledResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::task_board_remote_transport::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionOwnership, TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

const SETTLED_AT: &str = "2026-07-19T10:00:30Z";
const CLEANED_AT: &str = "2026-07-19T10:00:50Z";

#[tokio::test]
async fn cleanup_pending_controller_generation_decisively_owns_one_capacity_slot() {
    let fixture = controller_fixture(2).await;
    let settlement = claimed_cancelled_settlement(&fixture).await;
    let first = remote_candidate(&fixture, "first").await;
    let second = remote_candidate(&fixture, "second").await;

    assert!(matches!(
        offer_candidate(&fixture, &first, "2026-07-19T10:00:31Z").await,
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    assert!(matches!(
        offer_candidate(&fixture, &second, "2026-07-19T10:00:32Z").await,
        TaskBoardRemoteOfferOutcome::Unavailable
    ));
    assert_eq!(active_count(&fixture).await, 2);
    assert_eq!(assignment_count(&fixture).await, 2);

    complete_controller_cleanup(&fixture, &settlement).await;
    assert_eq!(active_count(&fixture).await, 1);
    assert!(matches!(
        offer_candidate(&fixture, &second, "2026-07-19T10:00:51Z").await,
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    assert_eq!(active_count(&fixture).await, 2);
    assert_eq!(assignment_count(&fixture).await, 3);
}

struct RemoteCandidate {
    execution: TaskBoardWorkflowExecutionRecord,
    attempt: TaskBoardExecutionAttemptRecord,
    request: RemoteOfferRequest,
}

async fn remote_candidate(fixture: &ControllerFixture, label: &str) -> RemoteCandidate {
    let item_id = format!("item-capacity-{label}");
    let execution_id = format!("execution-capacity-{label}");
    let mut item = crate::task_board::TaskBoardItem::new(
        item_id.clone(),
        format!("Remote capacity {label}"),
        "Prove one decisive controller capacity slot".into(),
        NOW.into(),
    );
    item.workflow_kind = fixture.execution.snapshot.workflow_kind;
    item.execution_repository = fixture.execution.snapshot.execution_repository.clone();
    let item = fixture
        .db
        .create_task_board_item(item)
        .await
        .expect("create capacity candidate item");
    let mut proposed = fixture.execution.clone();
    proposed.execution_id.clone_from(&execution_id);
    proposed.item_id = item_id;
    proposed.snapshot.item_revision = item.item_revision;
    if let Some(context) = proposed.snapshot.read_only_run_context.as_mut() {
        context.session_id = format!("session-capacity-{label}");
        context.title = format!("Remote capacity {label}");
    }
    proposed.ownership = TaskBoardExecutionOwnership {
        host_id: None,
        fencing_epoch: 0,
        resources: std::collections::BTreeMap::from([(
            "admission_owner".into(),
            workflow_owner(&execution_id),
        )]),
    };
    proposed.attempts.clear();
    let _execution = fixture
        .db
        .create_or_load_task_board_workflow_execution(&proposed)
        .await
        .expect("create capacity candidate execution")
        .execution;
    let mut attempt = fixture.attempt.clone();
    attempt.execution_id.clone_from(&execution_id);
    attempt.idempotency_key = format!("capacity-attempt-{label}");
    attempt.state = TaskBoardAttemptState::Preparing;
    fixture
        .db
        .create_task_board_execution_attempt(&attempt)
        .await
        .expect("create capacity candidate attempt");
    let execution = fixture
        .db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load capacity candidate execution")
        .expect("capacity candidate execution exists");
    let request = offer_request(
        &execution,
        &attempt,
        &format!("assignment-capacity-{label}"),
        HOST,
        INSTANCE,
    );
    RemoteCandidate {
        execution,
        attempt,
        request,
    }
}

async fn offer_candidate(
    fixture: &ControllerFixture,
    candidate: &RemoteCandidate,
    offered_at: &str,
) -> TaskBoardRemoteOfferOutcome {
    let offered =
        chrono::DateTime::parse_from_rfc3339(offered_at).expect("parse capacity offer time");
    let lease_expires_at = (offered + chrono::Duration::seconds(60))
        .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    fixture
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&candidate.execution),
            &TaskBoardExecutionAttemptCas::from(&candidate.attempt),
            &candidate.request,
            HOST,
            crate::daemon::db::TaskBoardRemoteOfferWindow::new(
                offered_at,
                &lease_expires_at,
                &candidate.request.deadline_at,
            ),
        )
        .await
        .expect("evaluate decisive controller offer capacity")
}

async fn claimed_cancelled_settlement(fixture: &ControllerFixture) -> RemoteSettledRequest {
    let accepted = accept_controller(fixture).await;
    let claimed = claim_controller(fixture, &accepted).await;
    let request = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: claimed.lease_id.clone().expect("claimed capacity lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "capacity cleanup proof".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal capacity cancellation");
    let response = RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        // Cancelling a claimed assignment must echo the observed claim evidence.
        claimed_at: claimed.claimed_at.clone(),
        started_at: None,
        workspace_ref: None,
        observed_at: "2026-07-19T10:00:20Z".into(),
    }
    .seal(&request)
    .expect("seal capacity cancellation response");
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, "2026-07-19T10:00:12Z")
        .await
        .expect("claim capacity cancel authority")
        .expect("capacity cancellation remains active");
    let cancelled = match fixture
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            HOST,
            "2026-07-19T10:00:21Z",
        )
        .await
        .expect("persist capacity cancellation")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected cancelled capacity owner, got {other:?}"),
    };
    settle_controller(fixture, &cancelled).await
}

async fn settle_controller(
    fixture: &ControllerFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Cancelled);
    let request = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: assignment
            .lease_id
            .clone()
            .expect("cancelled capacity lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal capacity settlement");
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
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("claim capacity settlement authority")
        .is_none()
    );
    fixture
        .db
        .record_task_board_remote_settlement_response(&request, &response, HOST)
        .await
        .expect("persist capacity settlement response");
    request
}

async fn complete_controller_cleanup(
    fixture: &ControllerFixture,
    settlement: &RemoteSettledRequest,
) {
    let request = RemoteCleanupObservationRequest::for_settlement(settlement)
        .expect("seal capacity cleanup observation");
    let response = RemoteCleanupObservationResponse::for_completed(&request, CLEANED_AT.into())
        .expect("seal capacity cleanup response");
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load capacity cleanup trust");
    assert!(
        fixture
            .db
            .claim_task_board_remote_cleanup_observation_fenced(&request, HOST, &trust)
            .await
            .expect("claim capacity cleanup observation")
            .is_none()
    );
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_cleanup_observation(&request, &response, HOST, &trust)
            .await
            .expect("persist capacity cleanup observation"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

async fn active_count(fixture: &ControllerFixture) -> u32 {
    fixture
        .db
        .task_board_remote_host_active_assignment_count_for_test(HOST)
        .await
        .expect("count active controller assignments")
}

async fn assignment_count(fixture: &ControllerFixture) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count durable controller assignments")
}
