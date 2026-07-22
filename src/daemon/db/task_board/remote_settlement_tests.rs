use sqlx::query_scalar;

use super::remote_assignment_test_support::*;
use super::remote_settlement_test_support::{
    completed_assignment_with_artifact, completed_settlement, store_and_verify_artifact,
};
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteSettledRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

const SETTLED_AT: &str = "2026-07-19T10:00:50Z";

#[tokio::test]
async fn lost_settlement_response_replays_first_timestamp_after_restart() {
    let fixture = executor_fixture(1).await;
    let (cancelled, request) = cancelled_assignment(&fixture).await;
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&cancelled.assignment_id)
            .await
            .expect("load absent settlement")
            .is_none()
    );

    let first = fixture
        .db
        .settle_task_board_remote_assignment(&request, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist settlement before response loss");
    let first_bytes = serde_json::to_vec(&first.response).expect("serialize first response");
    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart executor database");
    let replay = restarted
        .settle_task_board_remote_assignment(&request, PRINCIPAL, "2026-07-19T10:01:30Z")
        .await
        .expect("replay lost settlement response");

    assert_eq!(
        serde_json::to_vec(&replay.response).expect("serialize replay"),
        first_bytes
    );
    assert_eq!(replay.response.settled_at, SETTLED_AT);
    assert_eq!(
        replay.response.settlement_request_sha256,
        request.request_sha256
    );
    assert_eq!(replay.cleanup_ready_at, SETTLED_AT);
    let durable = restarted
        .task_board_remote_assignment(&cancelled.assignment_id)
        .await
        .expect("load cancelled assignment")
        .expect("cancelled assignment");
    assert_eq!(durable.last_mutation_kind.as_deref(), Some("cancel"));
    assert_eq!(
        durable.last_mutation_sha256.as_deref(),
        cancelled.last_mutation_sha256.as_deref()
    );
}

#[tokio::test]
async fn settlement_receipt_rejects_principal_and_request_collisions() {
    let fixture = executor_fixture(1).await;
    let (cancelled, request) = cancelled_assignment(&fixture).await;
    let first = fixture
        .db
        .settle_task_board_remote_assignment(&request, PRINCIPAL, SETTLED_AT)
        .await
        .expect("settle exact assignment");

    let principal_error = fixture
        .db
        .settle_task_board_remote_assignment(&request, "other-principal", SETTLED_AT)
        .await
        .expect_err("different principal must not replay settlement");
    assert!(principal_error.to_string().contains("immutable receipt"));
    let mut conflicting = request.clone();
    conflicting.lease_id = "other-lease".into();
    conflicting.request_sha256.clear();
    let conflicting = conflicting.seal().expect("seal conflicting settlement");
    let request_error = fixture
        .db
        .settle_task_board_remote_assignment(&conflicting, PRINCIPAL, SETTLED_AT)
        .await
        .expect_err("different request must not replace settlement");
    assert!(request_error.to_string().contains("immutable receipt"));
    assert_eq!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&cancelled.assignment_id)
            .await
            .expect("load immutable settlement")
            .expect("settlement receipt"),
        first
    );
}

#[tokio::test]
async fn artifact_bytes_survive_until_settlement_retention_then_prune_without_reopen() {
    let fixture = executor_fixture(1).await;
    let (completed, entry) = completed_assignment_with_artifact(&fixture).await;
    let fetch = store_and_verify_artifact(&fixture, &completed, &entry).await;
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&completed.assignment_id)
            .await
            .expect("load pre-settlement marker")
            .is_none()
    );

    let settlement = settle_and_complete_cleanup(&fixture, &completed).await;
    assert!(
        fixture
            .db
            .task_board_remote_artifact(&fetch, PRINCIPAL)
            .await
            .expect("fetch retained artifact after settlement")
            .is_some()
    );

    let early = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:09:59Z")
        .await
        .expect("retain evidence inside window");
    assert_eq!(early, super::TaskBoardRemoteEvidencePruneResult::default());
    let pruned = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("prune evidence after window");
    assert_eq!(
        (
            pruned.artifacts,
            pruned.offer_receipts,
            pruned.settlement_receipts
        ),
        (1, 1, 1)
    );
    assert!(
        fixture
            .db
            .task_board_remote_artifact(&fetch, PRINCIPAL)
            .await
            .expect("load pruned artifact")
            .is_none()
    );
    assert!(
        fixture
            .db
            .settle_task_board_remote_assignment(&settlement, PRINCIPAL, "2026-07-26T10:10:02Z",)
            .await
            .expect_err("expired settlement must not recreate cleanup authority")
            .to_string()
            .contains("retention expired")
    );
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&completed.assignment_id)
            .await
            .expect("load pruned settlement")
            .is_none()
    );
    assert!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &fixture.request,
                PRINCIPAL,
                INSTANCE,
                "2026-07-26T10:10:03Z",
            )
            .await
            .expect_err("pruned offer evidence must not reopen terminal assignment")
            .to_string()
            .contains("missing its immutable offer receipt")
    );
    let assignment = fixture
        .db
        .task_board_remote_assignment(&completed.assignment_id)
        .await
        .expect("load terminal assignment")
        .expect("terminal assignment retained");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Completed);
    let identity = super::remote_executor_identity(&assignment).expect("executor identity");
    assert_eq!(
        assignment.workspace_ref.as_deref(),
        Some(identity.workspace_ref.as_str())
    );
}

async fn settle_and_complete_cleanup(
    fixture: &ExecutorFixture,
    completed: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    let settlement = completed_settlement(fixture, completed);
    let receipt = fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist durable settlement");
    assert_eq!(receipt.cleanup_ready_at, SETTLED_AT);
    let TaskBoardRemoteMutationOutcome::Updated(cleaned) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-19T10:01:00Z",
        )
        .await
        .expect("persist completed cleanup marker")
    else {
        panic!("completed cleanup marker was not written");
    };
    assert_eq!(
        cleaned.cleanup_settlement_request_sha256.as_deref(),
        Some(settlement.request_sha256.as_str())
    );
    settlement
}

#[tokio::test]
async fn evidence_pruning_is_bounded_and_expired_offer_cannot_start() {
    let fixture = executor_fixture(1).await;
    accept_executor(&fixture, &fixture.request).await;
    let mut first_rejected = None;
    for index in 0..101_u64 {
        let execution_id = format!("execution-rejected-{index:03}");
        let mut request = detached_offer(
            &format!("assignment-rejected-{index:03}"),
            &format!("rejected-key-{index:03}"),
        );
        request.binding.execution_id = execution_id.clone();
        request.binding.fencing_epoch = index + 2;
        // The launch's workflow execution id must track the rebound binding execution id.
        request.launch = test_codex_launch(
            crate::task_board::TaskBoardExecutionPhase::Review,
            &execution_id,
            "review:reviewer",
            "Review the frozen revision",
        );
        request.request_sha256.clear();
        let request = request.seal().expect("seal rejected offer");
        assert!(matches!(
            fixture
                .db
                .accept_task_board_remote_assignment_offer(&request, PRINCIPAL, INSTANCE, NOW)
                .await
                .expect("record capacity rejection"),
            TaskBoardRemoteOfferOutcome::Rejected(_)
        ));
        if index == 0 {
            first_rejected = Some(request);
        }
    }

    let first = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-27T10:00:00Z")
        .await
        .expect("prune first bounded batch");
    assert_eq!(first.offer_receipts, 100);
    let remaining_rejected: i64 = query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_offer_receipts
         WHERE disposition = 'rejected'",
    )
    .fetch_one(fixture.db.pool())
    .await
    .expect("count retained rejected receipt");
    assert_eq!(remaining_rejected, 1);
    let second = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-27T10:00:01Z")
        .await
        .expect("prune second bounded batch");
    assert_eq!(second.offer_receipts, 1);

    let expired = first_rejected.expect("first rejected request");
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &expired,
                PRINCIPAL,
                INSTANCE,
                "2026-07-27T10:00:02Z",
            )
            .await
            .expect("expired offer is durably rejected again"),
        TaskBoardRemoteOfferOutcome::Rejected(_)
    ));
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&expired.binding.assignment_id)
            .await
            .expect("load expired assignment")
            .is_none()
    );
}

async fn cancelled_assignment(
    fixture: &ExecutorFixture,
) -> (super::TaskBoardRemoteAssignmentRecord, RemoteSettledRequest) {
    let accepted = accept_executor(fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim executor assignment");
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "controller cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancellation");
    let TaskBoardRemoteMutationOutcome::Updated(cancelled) = fixture
        .db
        .cancel_task_board_remote_assignment(&cancel, PRINCIPAL, "2026-07-19T10:00:30Z")
        .await
        .expect("cancel assignment")
    else {
        panic!("cancellation did not update assignment");
    };
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.expect("lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal settlement");
    (cancelled, settlement)
}
