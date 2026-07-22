use super::remote_assignment_test_support::*;
use super::remote_settlement_test_support::{
    completed_assignment_with_artifact, completed_settlement, store_and_verify_artifact,
    unknown_workspace_assignment,
};
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteOfferRequest, RemoteSettledRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};

const SETTLED_AT: &str = "2026-07-19T10:00:40Z";
const CLEANED_AT: &str = "2026-07-19T10:00:50Z";

#[tokio::test]
async fn unknown_capacity_drops_only_after_exact_cleanup_and_stays_dropped_after_prune() {
    let fixture = executor_fixture(1).await;
    let (unknown, settlement) = unknown_workspace_assignment(&fixture).await;
    assert_eq!(active_count(&fixture).await, 1);
    let before_settlement = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(&settlement, PRINCIPAL, CLEANED_AT)
        .await
        .expect_err("cleanup must require immutable settlement evidence");
    assert!(before_settlement.to_string().contains("settlement receipt"));

    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist exact settlement");
    assert_eq!(active_count(&fixture).await, 1);
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &distinct_offer("blocked", "execution-blocked", 2, DEADLINE),
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:45Z",
            )
            .await
            .expect("persist capacity rejection"),
        TaskBoardRemoteOfferOutcome::Rejected(_)
    ));

    let TaskBoardRemoteMutationOutcome::Updated(cleaned) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(&settlement, PRINCIPAL, CLEANED_AT)
        .await
        .expect("persist cleanup completion")
    else {
        panic!("first cleanup completion did not update assignment");
    };
    assert_cleanup_marker(&cleaned, &settlement, CLEANED_AT);
    assert_eq!(active_count(&fixture).await, 0);
    let TaskBoardRemoteMutationOutcome::Replayed(replayed) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-19T10:00:55Z",
        )
        .await
        .expect("replay cleanup completion")
    else {
        panic!("exact cleanup replay mutated assignment twice");
    };
    assert_cleanup_marker(&replayed, &settlement, CLEANED_AT);
    reject_cleanup_mismatch(&fixture, &settlement).await;

    let pruned = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("prune settled evidence");
    assert_eq!(pruned.settlement_receipts, 1);
    assert_eq!(active_count(&fixture).await, 0);
    let retained = fixture
        .db
        .task_board_remote_assignment(&unknown.assignment_id)
        .await
        .expect("load cleaned unknown assignment")
        .expect("cleaned unknown assignment retained");
    assert_cleanup_marker(&retained, &settlement, CLEANED_AT);
    let TaskBoardRemoteMutationOutcome::Replayed(after_prune) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-26T10:10:01Z",
        )
        .await
        .expect("replay cleanup after receipt pruning")
    else {
        panic!("pruned receipt reopened cleanup mutation");
    };
    assert_cleanup_marker(&after_prune, &settlement, CLEANED_AT);
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &distinct_offer("after", "execution-after", 3, "2026-07-26T10:20:00Z",),
                PRINCIPAL,
                INSTANCE,
                "2026-07-26T10:10:02Z",
            )
            .await
            .expect("accept after durable cleanup"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
}

#[tokio::test]
async fn completed_cleanup_marker_survives_receipt_and_artifact_pruning() {
    let fixture = executor_fixture(1).await;
    let (completed, entry) = completed_assignment_with_artifact(&fixture).await;
    let fetch = store_and_verify_artifact(&fixture, &completed, &entry).await;
    let settlement = completed_settlement(&fixture, &completed);
    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist completed settlement");
    let TaskBoardRemoteMutationOutcome::Updated(cleaned) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(&settlement, PRINCIPAL, CLEANED_AT)
        .await
        .expect("mark completed cleanup")
    else {
        panic!("completed cleanup did not update assignment");
    };
    assert_cleanup_marker(&cleaned, &settlement, CLEANED_AT);

    let pruned = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("prune completed evidence");
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
    let retained = fixture
        .db
        .task_board_remote_assignment(&completed.assignment_id)
        .await
        .expect("load cleaned completed assignment")
        .expect("cleaned completed assignment retained");
    assert_cleanup_marker(&retained, &settlement, CLEANED_AT);
}

#[tokio::test]
async fn claimed_cancelled_generation_holds_capacity_until_cleanup_after_restart() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    fixture
        .db
        .claim_task_board_remote_assignment(
            &claim_request(&fixture.request, &accepted),
            PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim capacity owner");
    let cancel = cancel_request(&fixture.request, &accepted);
    let TaskBoardRemoteMutationOutcome::Updated(cancelled) = fixture
        .db
        .cancel_task_board_remote_assignment(&cancel, PRINCIPAL, STARTED_AT)
        .await
        .expect("cancel claimed executor generation")
    else {
        panic!("claimed cancellation did not update assignment");
    };
    assert_eq!(active_count(&fixture).await, 1);
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &distinct_offer("cancel-blocked", "cancel-blocked", 2, DEADLINE),
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:25Z",
            )
            .await
            .expect("evaluate capacity during delayed cleanup"),
        TaskBoardRemoteOfferOutcome::Rejected(_)
    ));
    let settlement = terminal_settlement(&cancelled, RemoteAssignmentWireState::Cancelled);
    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("settle cancelled generation");

    let database_path = fixture._temp.path().join("executor.db");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("restart cancelled executor database");
    assert_eq!(active_count_db(&restarted).await, 1);
    restarted
        .complete_task_board_remote_assignment_cleanup(&settlement, PRINCIPAL, CLEANED_AT)
        .await
        .expect("complete cancelled cleanup after restart");
    assert_eq!(active_count_db(&restarted).await, 0);
    assert!(matches!(
        restarted
            .accept_task_board_remote_assignment_offer(
                &distinct_offer("cancel-released", "cancel-released", 3, DEADLINE),
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:55Z",
            )
            .await
            .expect("accept after cancelled cleanup"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
}

#[tokio::test]
async fn never_claimed_superseded_generation_releases_capacity_without_cleanup() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    assert_eq!(active_count(&fixture).await, 1);
    let TaskBoardRemoteMutationOutcome::Updated(superseded) = fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "offer rejected before claim",
            CLAIMED_AT,
        )
        .await
        .expect("supersede unclaimed generation")
    else {
        panic!("unclaimed generation did not supersede");
    };
    assert_eq!(superseded.assignment_id, accepted.assignment_id);
    assert!(superseded.claimed_at.is_none());
    assert_eq!(active_count(&fixture).await, 0);
    assert!(matches!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(
                &distinct_offer("supersede-released", "supersede-released", 2, DEADLINE),
                PRINCIPAL,
                INSTANCE,
                "2026-07-19T10:00:11Z",
            )
            .await
            .expect("accept after safe preclaim supersede"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
}

#[tokio::test]
async fn late_cleanup_after_restart_keeps_receipt_until_marker_then_prunes_safely() {
    let fixture = executor_fixture(1).await;
    let (unknown, settlement) = unknown_workspace_assignment(&fixture).await;
    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist settlement before delayed cleanup");
    let before_cleanup = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("retain settlement while cleanup is pending");
    assert_eq!(before_cleanup.settlement_receipts, 0);
    assert!(
        fixture
            .db
            .task_board_remote_settlement_receipt(&unknown.assignment_id)
            .await
            .expect("load pending cleanup receipt")
            .is_some()
    );
    assert_eq!(active_count(&fixture).await, 1);

    let database_path = fixture._temp.path().join("executor.db");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("restart executor database");
    let TaskBoardRemoteMutationOutcome::Updated(cleaned) = restarted
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-26T10:10:02Z",
        )
        .await
        .expect("complete delayed cleanup after restart")
    else {
        panic!("delayed cleanup did not persist its marker");
    };
    assert_cleanup_marker(&cleaned, &settlement, "2026-07-26T10:10:02Z");
    assert_eq!(active_count_db(&restarted).await, 0);

    let after_cleanup = restarted
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:03Z")
        .await
        .expect("prune settlement after cleanup marker");
    assert_eq!(after_cleanup.settlement_receipts, 1);
    assert!(
        restarted
            .task_board_remote_settlement_receipt(&unknown.assignment_id)
            .await
            .expect("load pruned delayed receipt")
            .is_none()
    );
    let TaskBoardRemoteMutationOutcome::Replayed(replayed) = restarted
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-26T10:10:04Z",
        )
        .await
        .expect("replay delayed cleanup after receipt pruning")
    else {
        panic!("pruned delayed cleanup marker was not idempotent");
    };
    assert_cleanup_marker(&replayed, &settlement, "2026-07-26T10:10:02Z");
    assert_eq!(active_count_db(&restarted).await, 0);
}

async fn active_count(fixture: &ExecutorFixture) -> u32 {
    active_count_db(&fixture.db).await
}

async fn active_count_db(db: &AsyncDaemonDb) -> u32 {
    db.task_board_remote_executor_active_assignment_count(HOST)
        .await
        .expect("count active executor assignments")
}

async fn reject_cleanup_mismatch(fixture: &ExecutorFixture, exact: &RemoteSettledRequest) {
    let mut mismatched = exact.clone();
    mismatched.lease_id = "mismatched-cleanup-lease".into();
    mismatched.request_sha256.clear();
    let mismatched = mismatched.seal().expect("seal mismatched cleanup request");
    let error = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(&mismatched, PRINCIPAL, CLEANED_AT)
        .await
        .expect_err("mismatched cleanup must fail closed");
    assert!(error.to_string().contains("terminal assignment evidence"));
}

fn assert_cleanup_marker(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    settlement: &RemoteSettledRequest,
    completed_at: &str,
) {
    assert_eq!(
        assignment.cleanup_settlement_request_sha256.as_deref(),
        Some(settlement.request_sha256.as_str())
    );
    assert_eq!(
        assignment.cleanup_completed_at.as_deref(),
        Some(completed_at)
    );
}

fn distinct_offer(
    label: &str,
    execution_id: &str,
    epoch: u64,
    deadline_at: &str,
) -> RemoteOfferRequest {
    let mut request = detached_offer(
        &format!("assignment-cleanup-{label}"),
        &format!("cleanup-key-{label}"),
    );
    request.binding.execution_id = execution_id.into();
    request.binding.fencing_epoch = epoch;
    request.deadline_at = deadline_at.into();
    // The launch's workflow execution id must track the rebound binding execution id.
    request.launch = test_codex_launch(
        crate::task_board::TaskBoardExecutionPhase::Review,
        execution_id,
        "review:reviewer",
        "Review the frozen revision",
    );
    request.request_sha256.clear();
    request.seal().expect("seal distinct capacity offer")
}

fn cancel_request(
    offer: &RemoteOfferRequest,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("cancel lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancellation")
}

fn terminal_settlement(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    state: RemoteAssignmentWireState,
) -> RemoteSettledRequest {
    let offer = assignment.require_offer().expect("strict terminal offer");
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("settlement lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: state,
        result_sha256: assignment.result_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal terminal settlement")
}
