use sqlx::{query, query_scalar};

use super::remote_assignment_active_fence::record_controller_reassignment_handoff_in_tx;
use super::remote_assignment_model::{insert_assignment_in_tx, load_assignment_in_tx};
use super::remote_assignment_test_support::{
    CLAIMED_AT, DEADLINE, HOST, INSTANCE, LEASE_EXPIRES, NOW, PRINCIPAL, SOURCE_REVISION,
    ExecutorFixture, accept_executor, claim_request, executor_fixture,
};
use super::remote_outbound_source_tests::{
    enable_implementation, snapshot_offer, source_recovery_owns,
};
use super::remote_outbound_sources::persist_outbound_source_in_tx;
use super::workflow_executions::{load_execution_in_tx, update_execution_in_tx};
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::tests::task_board::{
    PreparedRemoteOffer, prepare_remote_implementation_offer,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteOfferRequest, RemoteSettledRequest,
    RemoteSourceBundleUploadRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardRemoteAssignmentState,
    TaskBoardWorkflowExecutionCas,
};

const HANDOFF_AT: &str = "2026-07-19T10:00:10Z";
const SUCCESSOR_LEASE_EXPIRES: &str = "2026-07-19T10:01:10Z";

#[tokio::test]
async fn settled_cleaned_outbound_bytes_prune_without_reopening_authority() {
    let fixture = executor_fixture(1).await;
    enable_implementation(&fixture.db)
        .await
        .expect("enable implementation capability");
    let (offer, content) = snapshot_offer(&fixture.request);
    let accepted = accept_and_mirror_source(&fixture, &offer, &content).await;
    let cancelled = cancel_settle_and_cleanup(&fixture, &offer, &accepted).await;
    assert_settled_source_retention(&fixture, &offer, &cancelled).await;
}

async fn accept_and_mirror_source(
    fixture: &ExecutorFixture,
    offer: &RemoteOfferRequest,
    content: &[u8],
) -> TaskBoardRemoteAssignmentRecord {
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), content)
        .expect("seal executor source upload");
    fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("store executor source bytes");
    let accepted = accept_executor(fixture, offer).await;
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("persist mirrored outbound source")
        .await
        .expect("begin outbound source persistence");
    persist_outbound_source_in_tx(&mut transaction, offer, Some(content), NOW)
        .await
        .expect("persist outbound source bytes");
    transaction.commit().await.expect("commit outbound source");
    accepted
}

async fn cancel_settle_and_cleanup(
    fixture: &ExecutorFixture,
    offer: &RemoteOfferRequest,
    accepted: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .claim_task_board_remote_assignment(&claim_request(offer, accepted), PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim source assignment");
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancelled".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal source cancellation");
    let TaskBoardRemoteMutationOutcome::Updated(cancelled) = fixture
        .db
        .cancel_task_board_remote_assignment(&cancel, PRINCIPAL, "2026-07-19T10:00:30Z")
        .await
        .expect("cancel source assignment")
    else {
        panic!("source cancellation did not update");
    };
    let settlement = cancelled_settlement(offer, accepted);
    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, "2026-07-19T10:00:40Z")
        .await
        .expect("settle source assignment");
    assert!(matches!(
        fixture
            .db
            .complete_task_board_remote_assignment_cleanup(
                &settlement,
                PRINCIPAL,
                "2026-07-19T10:00:50Z",
            )
            .await
            .expect("complete source cleanup"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    cancelled
}

fn cancelled_settlement(
    offer: &RemoteOfferRequest,
    accepted: &TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal source settlement")
}

async fn assert_settled_source_retention(
    fixture: &ExecutorFixture,
    offer: &RemoteOfferRequest,
    cancelled: &TaskBoardRemoteAssignmentRecord,
) {
    assert!(outbound_source(&fixture.db, offer).await.is_some());
    assert_eq!(
        fixture
            .db
            .prune_task_board_remote_execution_evidence("2026-07-26T10:09:59Z")
            .await
            .expect("retain outbound source inside window")
            .source_bundle_contents,
        0
    );
    let pruned = fixture
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("prune settled source bytes");
    assert_eq!(pruned.source_bundle_contents, 2);
    assert!(pruned_outbound_source(&fixture.db, offer).await);
    let durable = fixture
        .db
        .task_board_remote_assignment(&cancelled.assignment_id)
        .await
        .expect("load retained cancelled assignment")
        .expect("cancelled assignment retained");
    assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Cancelled);
    assert!(durable.cleanup_completed_at.is_some());
    assert!(!source_recovery_owns(&fixture.db, offer).await);
    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart after outbound source pruning");
    assert!(pruned_outbound_source(&reopened, offer).await);
}

#[tokio::test]
async fn remote_reassigned_predecessor_prunes_only_after_exact_successor_handoff() {
    let prepared = prepare_remote_implementation_offer(
        "source-retention-reassignment",
        "/tmp/source-retention-reassignment",
        SOURCE_REVISION,
    )
    .await;
    let (predecessor_offer, content) = snapshot_offer(&prepared.offer);
    persist_predecessor(&prepared, &predecessor_offer, &content).await;
    let successor_offer =
        persist_exact_successor_handoff(&prepared, &predecessor_offer, &content).await;
    assert_reassigned_source_retention(
        &prepared,
        &predecessor_offer,
        &successor_offer,
        &content,
    )
    .await;
}

async fn persist_predecessor(
    prepared: &PreparedRemoteOffer,
    offer: &RemoteOfferRequest,
    content: &[u8],
) {
    assert!(matches!(
        prepared
            .db
            .offer_task_board_remote_assignment_with_source(
                &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
                &crate::task_board::TaskBoardExecutionAttemptCas::from(&prepared.attempt),
                offer,
                Some(content),
                HOST,
                NOW,
                LEASE_EXPIRES,
                DEADLINE,
            )
            .await
            .expect("persist predecessor source offer"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
}

async fn persist_exact_successor_handoff(
    prepared: &PreparedRemoteOffer,
    predecessor_offer: &RemoteOfferRequest,
    content: &[u8],
) -> RemoteOfferRequest {
    let mut transaction = prepared
        .db
        .begin_immediate_transaction("test exact remote reassignment handoff")
        .await
        .expect("begin remote reassignment");
    let predecessor = load_assignment_in_tx(&mut transaction, &predecessor_offer.binding.assignment_id)
        .await
        .expect("load predecessor")
        .expect("predecessor exists");
    let parent = load_execution_in_tx(&mut transaction, &prepared.execution_id)
        .await
        .expect("load predecessor parent")
        .expect("predecessor parent exists");
    let successor_offer = successor_offer(predecessor_offer, &parent);
    supersede_for_reassignment(&mut transaction, &predecessor.assignment_id).await;
    let successor_parent = successor_parent(&parent, &successor_offer);
    update_execution_in_tx(
        &mut transaction,
        &TaskBoardWorkflowExecutionCas::from(&parent),
        &successor_parent,
    )
    .await
    .expect("persist exact successor parent");
    insert_successor(&mut transaction, &successor_offer, content).await;
    let predecessor = load_assignment_in_tx(&mut transaction, &predecessor.assignment_id)
        .await
        .expect("reload predecessor")
        .expect("predecessor retained");
    let successor = load_assignment_in_tx(&mut transaction, &successor_offer.binding.assignment_id)
        .await
        .expect("load successor")
        .expect("successor exists");
    assert_and_record_exact_handoff(
        &mut transaction,
        &predecessor,
        &successor,
        &parent,
        &successor_parent,
    )
    .await;
    transaction.commit().await.expect("commit remote reassignment");
    successor_offer
}

fn successor_offer(
    predecessor: &RemoteOfferRequest,
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
) -> RemoteOfferRequest {
    let mut successor = predecessor.clone();
    successor.binding.assignment_id.push_str("-successor");
    successor.binding.fencing_epoch += 1;
    successor.binding.execution_record_sha256 =
        TaskBoardWorkflowExecutionCas::from(parent).record_sha256;
    successor.request_sha256.clear();
    successor.seal().expect("seal successor source offer")
}

fn successor_parent(
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    offer: &RemoteOfferRequest,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let mut successor = parent.clone();
    successor.ownership.fencing_epoch = offer.binding.fencing_epoch;
    successor.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        format!("remote:{}", offer.binding.assignment_id),
    );
    successor.updated_at = HANDOFF_AT.into();
    successor
}

async fn insert_successor(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    offer: &RemoteOfferRequest,
    content: &[u8],
) {
    insert_assignment_in_tx(
        transaction,
        offer,
        HOST,
        HANDOFF_AT,
        None,
        SUCCESSOR_LEASE_EXPIRES,
        DEADLINE,
        None,
        None,
        None,
    )
    .await
    .expect("insert pristine successor");
    persist_outbound_source_in_tx(transaction, offer, Some(content), HANDOFF_AT)
        .await
        .expect("persist successor source bytes");
}

async fn assert_and_record_exact_handoff(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    successor: &TaskBoardRemoteAssignmentRecord,
    old_parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    successor_parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
) {
    assert!(
        record_controller_reassignment_handoff_in_tx(
            transaction,
            predecessor,
            successor,
            old_parent,
            HANDOFF_AT,
        )
        .await
        .expect_err("old predecessor parent must not authorize handoff")
        .to_string()
        .contains("exact persisted successor target")
    );
    record_controller_reassignment_handoff_in_tx(
        transaction,
        predecessor,
        successor,
        successor_parent,
        HANDOFF_AT,
    )
    .await
    .expect("record exact successor handoff");
}

async fn assert_reassigned_source_retention(
    prepared: &PreparedRemoteOffer,
    predecessor: &RemoteOfferRequest,
    successor: &RemoteOfferRequest,
    content: &[u8],
) {
    assert_eq!(settlement_count(&prepared.db).await, 0);
    let pruned = prepared
        .db
        .prune_task_board_remote_execution_evidence("2026-07-26T10:10:01Z")
        .await
        .expect("prune handed-off predecessor bytes");
    assert_eq!(pruned.source_bundle_contents, 1);
    assert!(pruned_outbound_source(&prepared.db, predecessor).await);
    let successor_source = outbound_source(&prepared.db, successor)
        .await
        .expect("successor bytes retained");
    assert_eq!(
        successor_source
            .validate()
            .expect("validate successor bytes"),
        content
    );
    let reopened = prepared.db.reopen().await;
    assert_eq!(settlement_count(&reopened).await, 0);
    assert!(pruned_outbound_source(&reopened, predecessor).await);
    assert!(outbound_source(&reopened, successor).await.is_some());
}

async fn supersede_for_reassignment(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    assignment_id: &str,
) {
    assert_eq!(
        query(
            "UPDATE task_board_remote_assignments
             SET state = 'superseded', completed_at = ?2,
                 error = 'source_bundle_absent_after_executor_restart', updated_at = ?2
             WHERE assignment_id = ?1 AND state = 'offered'",
        )
        .bind(assignment_id)
        .bind(HANDOFF_AT)
        .execute(transaction.as_mut())
        .await
        .expect("supersede predecessor")
        .rows_affected(),
        1
    );
}

async fn outbound_source(
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
) -> Option<crate::daemon::task_board_remote_transport::wire::RemoteSourceBundleUploadRequest> {
    db.task_board_remote_outbound_source_upload(
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await
    .expect("load readable outbound source")
}

async fn pruned_outbound_source(db: &AsyncDaemonDb, offer: &RemoteOfferRequest) -> bool {
    db.task_board_remote_outbound_source_upload(
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await
    .expect_err("outbound source bytes must be pruned")
    .to_string()
    .contains("durably pruned")
}

async fn settlement_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_settlement_receipts")
        .fetch_one(db.pool())
        .await
        .expect("count settlement receipts")
}
