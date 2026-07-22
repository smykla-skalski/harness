use super::remote_assignment_model::insert_assignment_in_tx;
use super::remote_assignment_test_support::{
    DEADLINE, HOST, LEASE_EXPIRES, NOW, PRINCIPAL, SOURCE_REVISION, detached_offer,
};
use super::remote_outbound_source_tests::{
    enable_implementation, snapshot_offer, source_recovery_owns,
};
use super::remote_outbound_sources::persist_outbound_source_in_tx;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::tests::task_board::{
    PreparedRemoteOffer, prepare_remote_implementation_offer,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardExecutionAttemptCas, TaskBoardExecutionPhase,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn generic_expiry_defers_exact_source_owner_until_conclusive_rejection() {
    let prepared = prepare_remote_implementation_offer(
        "source-owned-expiry",
        "/tmp/source-owned-expiry",
        SOURCE_REVISION,
    )
    .await;
    let offer = persist_source_owned_offer(&prepared).await;
    assert_source_owned_recovery_defers(&prepared.db, &offer).await;

    let restarted = prepared.db.reopen().await;
    assert_recovery_defers(&restarted, &offer, "2026-07-19T10:02:01Z").await;
    restarted
        .claim_task_board_remote_offer_io_authority(&offer, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim exact offer authority")
        .expect("offer remains active");
    assert!(source_recovery_owns(&restarted, &offer).await);
    assert_recovery_defers(&restarted, &offer, "2026-07-19T10:02:02Z").await;
    let unresolved_parent = restarted
        .task_board_workflow_execution(&offer.binding.execution_id)
        .await
        .expect("load unresolved source parent")
        .expect("unresolved source parent");
    let expected_remote_target = format!("remote:{}", offer.binding.assignment_id);
    assert_eq!(
        unresolved_parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some(expected_remote_target.as_str())
    );
    restarted
        .record_task_board_remote_offer_response(
            &RemoteOfferResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: offer.binding.clone(),
                offer_request_sha256: offer.request_sha256.clone(),
                disposition: RemoteOfferDisposition::Rejected,
                lease: None,
                rejection_code: Some("executor_unavailable".into()),
            },
            HOST,
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("apply conclusive source offer rejection");
    assert!(!source_recovery_owns(&restarted, &offer).await);
    let assignment = restarted
        .task_board_remote_assignment(&offer.binding.assignment_id)
        .await
        .expect("load rejected source assignment")
        .expect("rejected assignment retained");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Superseded);
    let parent = restarted
        .task_board_workflow_execution(&offer.binding.execution_id)
        .await
        .expect("load local fallback parent")
        .expect("fallback parent");
    assert_eq!(
        parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(
        restarted
            .task_board_remote_assignment_recovery_deadline()
            .await
            .expect("load post-fallback recovery deadline"),
        None
    );
    let after_fallback = restarted
        .recover_task_board_remote_assignments("2026-07-19T10:02:03Z")
        .await
        .expect("post-fallback recovery does not spin");
    assert!(after_fallback.recovered.is_empty());
    assert!(after_fallback.failures.is_empty());
    assert!(!after_fallback.incomplete);
}

async fn persist_source_owned_offer(prepared: &PreparedRemoteOffer) -> RemoteOfferRequest {
    let (offer, content) = snapshot_offer(&prepared.offer);
    assert!(matches!(
        prepared
            .db
            .offer_task_board_remote_assignment_with_source(
                &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
                &TaskBoardExecutionAttemptCas::from(&prepared.attempt),
                &offer,
                Some(&content),
                HOST,
                NOW,
                LEASE_EXPIRES,
                DEADLINE,
            )
            .await
            .expect("persist source-owned offer"),
        super::TaskBoardRemoteOfferOutcome::Created(_)
    ));
    offer
}

async fn assert_source_owned_recovery_defers(db: &AsyncDaemonDb, offer: &RemoteOfferRequest) {
    assert!(source_recovery_owns(db, offer).await);
    assert_eq!(
        db.task_board_remote_assignment_recovery_deadline()
            .await
            .expect("load source-owned recovery deadline"),
        None
    );
    assert_recovery_defers(db, offer, "2026-07-19T10:02:00Z").await;
}

#[tokio::test]
async fn protected_source_backlog_never_starves_later_expiry_after_restart() {
    let fixture = super::remote_assignment_test_support::executor_fixture(1).await;
    enable_implementation(&fixture.db)
        .await
        .expect("enable source offer capability");
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("seed protected source recovery backlog")
        .await
        .expect("begin protected source backlog");
    let mut first_protected = None;
    for index in 0..129_u64 {
        let (offer, content) = protected_offer(&fixture.request, index);
        insert_assignment_in_tx(
            &mut transaction,
            &offer,
            PRINCIPAL,
            NOW,
            None,
            LEASE_EXPIRES,
            DEADLINE,
            None,
            None,
            None,
        )
        .await
        .expect("insert protected source assignment");
        persist_outbound_source_in_tx(&mut transaction, &offer, Some(&content), NOW)
            .await
            .expect("persist protected source bytes");
        first_protected.get_or_insert(offer);
    }
    let mut actionable = detached_offer("zz-actionable-expiry", "actionable-expiry-key");
    actionable.binding.execution_id = "execution-actionable-expiry".into();
    actionable.binding.fencing_epoch = 500;
    // The launch's workflow execution id must track the rebound binding execution id.
    actionable.launch = test_codex_launch(
        TaskBoardExecutionPhase::Review,
        &actionable.binding.execution_id,
        &actionable.binding.action_key,
        "Review the frozen revision",
    );
    actionable.request_sha256.clear();
    let actionable = actionable.seal().expect("seal actionable expiry");
    insert_assignment_in_tx(
        &mut transaction,
        &actionable,
        PRINCIPAL,
        NOW,
        None,
        LEASE_EXPIRES,
        DEADLINE,
        None,
        None,
        None,
    )
    .await
    .expect("insert actionable expiry");
    transaction
        .commit()
        .await
        .expect("commit protected source backlog");

    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart before bounded recovery scan");
    let batch = restarted
        .recover_task_board_remote_assignments("2026-07-19T10:02:00Z")
        .await
        .expect("recover later actionable expiry");
    assert_eq!(batch.recovered.len(), 1);
    assert_eq!(
        batch.recovered[0].assignment_id,
        actionable.binding.assignment_id
    );
    assert!(!batch.incomplete);
    assert!(batch.failures.is_empty());
    let protected = first_protected.expect("first protected offer");
    let retained = restarted
        .task_board_remote_assignment(&protected.binding.assignment_id)
        .await
        .expect("load protected assignment")
        .expect("protected assignment retained");
    assert_eq!(retained.state, TaskBoardRemoteAssignmentState::Offered);
    assert!(source_recovery_owns(&restarted, &protected).await);
    assert_eq!(
        restarted
            .task_board_remote_assignment_recovery_deadline()
            .await
            .expect("load recovery deadline after bounded scan"),
        None
    );
}

fn protected_offer(template: &RemoteOfferRequest, index: u64) -> (RemoteOfferRequest, Vec<u8>) {
    let (mut offer, content) = snapshot_offer(template);
    offer.binding.assignment_id = format!("aa-protected-source-{index:03}");
    offer.binding.execution_id = format!("execution-protected-source-{index:03}");
    offer.binding.idempotency_key = format!("protected-source-key-{index:03}");
    offer.binding.fencing_epoch = index + 2;
    offer.launch = test_codex_launch(
        TaskBoardExecutionPhase::Implementation,
        &offer.binding.execution_id,
        &offer.binding.action_key,
        "Implement the frozen task plan.",
    );
    offer.request_sha256.clear();
    (offer.seal().expect("seal protected source offer"), content)
}

async fn assert_recovery_defers(
    db: &AsyncDaemonDb,
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    now: &str,
) {
    let batch = db
        .recover_task_board_remote_assignments(now)
        .await
        .expect("skip source-owned due generation");
    assert!(batch.recovered.is_empty());
    assert!(batch.failures.is_empty());
    let assignment = db
        .task_board_remote_assignment(&offer.binding.assignment_id)
        .await
        .expect("load source-owned assignment")
        .expect("source-owned assignment");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Offered);
    assert!(source_recovery_owns(db, offer).await);
}
