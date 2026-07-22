use super::remote_assignment_test_support::*;
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLease, RemoteOfferDisposition, RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE, TaskBoardExecutionState,
    TaskBoardRemoteAssignmentState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
};

#[tokio::test]
async fn offer_authority_fences_stop_until_atomic_settlement() {
    let fixture = controller_fixture(1).await;
    let TaskBoardRemoteOfferOutcome::Created(_) = offer_controller(&fixture).await else {
        panic!("controller offer was not created");
    };
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim offer authority")
        .expect("active offer authority");
    let claimed = load_execution(&fixture).await;
    let stopped = human_required(&claimed, "2026-07-19T10:00:02Z");
    let error = fixture
        .db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&claimed),
            &stopped,
        )
        .await
        .expect_err("owned offer I/O must fence stop");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");

    fixture
        .db
        .record_task_board_remote_offer_response(
            &accepted_response(&fixture.request),
            HOST,
            "2026-07-19T10:00:03Z",
        )
        .await
        .expect("settle accepted offer");
    let settled = load_execution(&fixture).await;
    assert!(
        !settled
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE)
    );
    let stopped = human_required(&settled, &settled.updated_at);
    assert!(matches!(
        fixture
            .db
            .compare_and_set_task_board_workflow_execution(
                &TaskBoardWorkflowExecutionCas::from(&settled),
                &stopped,
            )
            .await
            .expect("stop after settlement"),
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));
    let assignment = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load stopped assignment")
        .expect("assignment");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Superseded);
    assert!(
        fixture
            .db
            .claim_task_board_remote_claim_io_authority(
                &claim_request(&fixture.request, &assignment),
                HOST,
                "2026-07-19T10:00:05Z",
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn io_authority_persists_the_canonical_monotonic_authority_time() {
    let fixture = controller_fixture(1).await;
    let _ = offer_controller(&fixture).await;
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(
            &fixture.request,
            HOST,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer authority")
        .expect("active offer authority");

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.updated_at, "2026-07-19T10:00:01Z");
}

#[tokio::test]
async fn late_first_acceptance_retains_l1_and_switches_once_to_local_fallback() {
    let fixture = controller_fixture(1).await;
    let _ = offer_controller(&fixture).await;
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:30Z")
        .await
        .expect("claim offer authority")
        .expect("offer authority");
    let response = accepted_response(&fixture.request);
    let late = match fixture
        .db
        .record_task_board_remote_offer_response(&response, HOST, AFTER_EXPIRY)
        .await
        .expect("retain late acceptance")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected one local fallback, got {other:?}"),
    };
    assert_eq!(late.state, TaskBoardRemoteAssignmentState::Superseded);
    assert_eq!(late.lease_id.as_deref(), Some("lease-l1"));
    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(execution.attempts.len(), 2);
    let sequence = fixture
        .db
        .current_change_sequence()
        .await
        .expect("sequence");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_offer_response(&response, HOST, "2026-07-19T10:03:00Z",)
            .await
            .expect("replay immutable late acceptance"),
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
            .exact_task_board_remote_offer_receipt(&fixture.request, HOST)
            .await
            .expect("lookup accepted receipt")
            .expect("accepted receipt")
            .response()
            .expect("reconstruct accepted response"),
        response
    );
}

#[tokio::test]
async fn persisted_malformed_authority_fails_closed_on_load_and_cas() {
    for corruption in ["both", "bad_digest", "wrong_state"] {
        let fixture = controller_fixture(1).await;
        let _ = offer_controller(&fixture).await;
        fixture
            .db
            .claim_task_board_remote_offer_io_authority(
                &fixture.request,
                HOST,
                "2026-07-19T10:00:01Z",
            )
            .await
            .expect("claim authority")
            .expect("authority");
        corrupt_authority(&fixture, corruption).await;
        let error = fixture
            .db
            .task_board_workflow_execution(&fixture.execution.execution_id)
            .await
            .expect_err("corrupt authority must fail persisted load");
        assert_eq!(error.code(), "WORKFLOW_IO");
        assert_corruption_error(&error, corruption);
        let stopped = human_required(&fixture.execution, "2026-07-19T10:00:02Z");
        let error = fixture
            .db
            .compare_and_set_task_board_workflow_execution(
                &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &stopped,
            )
            .await
            .expect_err("corrupt authority must fail CAS");
        assert_eq!(error.code(), "WORKFLOW_IO");
        assert_corruption_error(&error, corruption);
    }
}

fn assert_corruption_error(error: &CliError, corruption: &str) {
    let expected = if corruption == "wrong_state" {
        "contradict structured state"
    } else {
        "authorit"
    };
    assert!(error.to_string().contains(expected), "{error}");
}

fn accepted_response(
    request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: LEASE_EXPIRES.into(),
        }),
        rejection_code: None,
    }
}

fn human_required(
    current: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let mut stopped = current.clone();
    stopped.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    stopped.blocked_reason = Some("operator_stop".into());
    stopped.updated_at = now.into();
    stopped.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::HumanRequired,
        summary: "operator stopped remote workflow".into(),
        recorded_at: now.into(),
    });
    stopped
}

async fn corrupt_authority(fixture: &ControllerFixture, corruption: &str) {
    if corruption == "wrong_state" {
        sqlx::query(
            "UPDATE task_board_workflow_executions SET state = 'running'
             WHERE execution_id = ?1",
        )
        .bind(&fixture.execution.execution_id)
        .execute(fixture.db.pool())
        .await
        .expect("corrupt authority state");
        return;
    }
    let mut ownership = sqlx::query_scalar::<_, String>(
        "SELECT resource_ownership_json FROM task_board_workflow_executions
         WHERE execution_id = ?1",
    )
    .bind(&fixture.execution.execution_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load ownership json");
    let mut value =
        serde_json::from_str::<serde_json::Value>(&ownership).expect("decode ownership");
    let resources = value["resources"]
        .as_object_mut()
        .expect("ownership resources");
    if corruption == "both" {
        resources.insert(
            TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE.into(),
            serde_json::Value::String("b".repeat(64)),
        );
    } else {
        resources.insert(
            TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE.into(),
            serde_json::Value::String("BAD".into()),
        );
    }
    ownership = serde_json::to_string(&value).expect("encode corrupt ownership");
    sqlx::query(
        "UPDATE task_board_workflow_executions SET resource_ownership_json = ?2
         WHERE execution_id = ?1",
    )
    .bind(&fixture.execution.execution_id)
    .bind(ownership)
    .execute(fixture.db.pool())
    .await
    .expect("persist corrupt ownership");
}

async fn load_execution(
    fixture: &ControllerFixture,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}
