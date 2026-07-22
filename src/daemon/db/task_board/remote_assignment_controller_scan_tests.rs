use super::remote_assignment_generation_tests::accept_controller;
use super::remote_assignment_recovery_queue::{
    CONTROLLER_PROGRESSION_QUARANTINE_CODE, RawRecoveryCandidate,
    quarantine_remote_recovery_failure_in_tx,
};
use super::remote_assignment_test_support::{
    AFTER_EXPIRY, CLAIMED_AT, ControllerFixture, HOST, LEASE_EXPIRES, controller_fixture,
    offer_controller,
};
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteControllerScanStep,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteLease,
    RemoteOfferDisposition, RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardItem, TaskBoardRemoteAssignmentState};
use sqlx::{query, query_scalar};

const SCAN_AT: &str = "2026-07-20T12:00:00Z";

#[tokio::test]
async fn controller_scan_replays_a_durable_active_generation_across_restart() {
    let fixture = controller_fixture(1).await;
    assert!(matches!(
        offer_controller(&fixture).await,
        TaskBoardRemoteOfferOutcome::Created(_)
    ));

    let first = fixture
        .db
        .next_task_board_remote_controller_assignment(SCAN_AT)
        .await
        .expect("scan controller assignment")
        .expect("active controller assignment");
    let TaskBoardRemoteControllerScanStep::Assignment(first) = first else {
        panic!("healthy controller assignment was quarantined");
    };
    assert_eq!(
        first.assignment.assignment_id,
        fixture.request.binding.assignment_id
    );

    drop(fixture.db);
    let reopened =
        crate::daemon::db::AsyncDaemonDb::connect(&fixture._temp.path().join("controller.db"))
            .await
            .expect("reopen controller database");
    let replay = reopened
        .next_task_board_remote_controller_assignment(SCAN_AT)
        .await
        .expect("rescan controller assignment")
        .expect("replayed controller assignment");
    let TaskBoardRemoteControllerScanStep::Assignment(replay) = replay else {
        panic!("healthy replayed controller assignment was quarantined");
    };
    assert_eq!(
        replay.assignment.assignment_id,
        fixture.request.binding.assignment_id
    );
    assert!(
        !reopened
            .complete_task_board_remote_controller_assignment_scan(&replay, SCAN_AT)
            .await
            .expect("acknowledge replayed controller assignment")
    );
}

#[tokio::test]
async fn malformed_controller_generation_is_quarantined_without_reblocking_the_scan() {
    let fixture = controller_fixture(1).await;
    assert!(matches!(
        offer_controller(&fixture).await,
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("corrupt controller scan fixture")
        .await
        .expect("begin corruption transaction");
    query("PRAGMA ignore_check_constraints = ON")
        .execute(transaction.as_mut())
        .await
        .expect("permit semantic corruption");
    query(
        "UPDATE task_board_remote_assignments SET request_sha256 = 'not-a-digest'
         WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .execute(transaction.as_mut())
    .await
    .expect("corrupt assignment digest");
    query("PRAGMA ignore_check_constraints = OFF")
        .execute(transaction.as_mut())
        .await
        .expect("restore check constraints");
    transaction.commit().await.expect("commit corruption");

    let step = fixture
        .db
        .next_task_board_remote_controller_assignment(SCAN_AT)
        .await
        .expect("scan malformed controller assignment")
        .expect("malformed controller assignment remains scan-visible");
    let TaskBoardRemoteControllerScanStep::Quarantined(failure) = step else {
        panic!("malformed controller assignment unexpectedly decoded");
    };
    assert_eq!(failure.assignment_id, fixture.request.binding.assignment_id);
    assert!(!failure.scan_incomplete);
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_remote_recovery_quarantine
             WHERE assignment_id = ?1",
        )
        .bind(&fixture.request.binding.assignment_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("count controller quarantine"),
        1
    );
    assert!(
        fixture
            .db
            .next_task_board_remote_controller_assignment(SCAN_AT)
            .await
            .expect("continue after malformed controller assignment")
            .is_none()
    );
}

#[tokio::test]
async fn terminal_handoff_retry_does_not_hold_the_global_progression_gate() {
    let fixture = controller_fixture(1).await;
    let accepted = accept_controller(&fixture).await;
    let request = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.expect("accepted lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "offline executor after exact terminal handoff".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal terminal handoff cancellation");
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
    .expect("seal terminal handoff cancellation response");
    // The cancel must settle inside the lease window; the scan below runs long after.
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&request, HOST, CLAIMED_AT)
        .await
        .expect("claim terminal handoff cancellation")
        .expect("terminal handoff cancellation remains active");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_cancel(&request, &response, HOST, CLAIMED_AT)
            .await
            .expect("persist terminal projection handoff"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));

    let step = fixture
        .db
        .next_task_board_remote_controller_assignment(SCAN_AT)
        .await
        .expect("scan terminal cleanup retry")
        .expect("terminal cleanup remains scan-visible");
    let TaskBoardRemoteControllerScanStep::Assignment(item) = step else {
        panic!("terminal cleanup retry was unexpectedly quarantined");
    };
    fixture
        .db
        .defer_task_board_remote_controller_assignment_scan(&item, SCAN_AT)
        .await
        .expect("defer offline terminal cleanup retry");

    assert!(
        !fixture
            .db
            .task_board_remote_controller_progression_is_blocked()
            .await
            .expect("load global progression gate after terminal handoff")
    );
    fixture
        .db
        .create_task_board_item(TaskBoardItem::new(
            "unrelated-local-after-terminal-handoff".into(),
            "Unrelated local callback".into(),
            "Must not wait for remote cleanup retry".into(),
            SCAN_AT.into(),
        ))
        .await
        .expect("run unrelated local callback after terminal handoff");
}

#[tokio::test]
async fn late_local_fallback_with_retained_lease_is_not_scan_visible() {
    let fixture = controller_fixture(1).await;
    let assignment = late_accept_local_fallback(&fixture).await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Superseded);
    assert_eq!(assignment.lease_id.as_deref(), Some("lease-l1"));

    // The local fallback already advanced the parent to a fresh local attempt, so the
    // resolved superseded generation must drop out of the controller cleanup scan. A
    // never-claimed offer has no executor workspace to settle.
    assert!(
        fixture
            .db
            .next_task_board_remote_controller_assignment(SCAN_AT)
            .await
            .expect("scan resolved local fallback")
            .is_none(),
        "resolved local fallback generation must not be scan-visible"
    );
    assert!(
        !fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load before-local-work fence after local fallback"),
        "resolved local fallback must release the before-local-work fence"
    );
}

#[tokio::test]
async fn quarantined_local_fallback_with_retained_lease_does_not_block_progression() {
    let fixture = controller_fixture(1).await;
    let assignment = late_accept_local_fallback(&fixture).await;

    // A daemon predating the resolved-handoff scan exclusion could have quarantined this
    // generation under the progression code. The global gate must still treat the resolved
    // local fallback as settled rather than halting all local work daemon-wide.
    let candidate = RawRecoveryCandidate {
        assignment_id: assignment.assignment_id.clone(),
        fencing_epoch: i64::try_from(assignment.fencing_epoch).expect("fencing epoch fits i64"),
        assignment_state: assignment.state.as_str().into(),
        assignment_updated_at: assignment.updated_at.clone(),
        request_sha256: assignment.request_sha256.clone(),
        lease_id: assignment.lease_id.clone(),
    };
    let mut transaction = fixture
        .db
        .begin_immediate_transaction("test controller progression quarantine")
        .await
        .expect("begin quarantine transaction");
    quarantine_remote_recovery_failure_in_tx(
        &mut transaction,
        &candidate,
        SCAN_AT,
        CONTROLLER_PROGRESSION_QUARANTINE_CODE,
    )
    .await
    .expect("quarantine resolved local fallback");
    transaction.commit().await.expect("commit quarantine");

    assert!(
        !fixture
            .db
            .task_board_remote_controller_progression_is_blocked()
            .await
            .expect("load global progression gate for resolved local fallback"),
        "resolved local fallback must not hold the global progression gate"
    );
}

async fn late_accept_local_fallback(
    fixture: &ControllerFixture,
) -> TaskBoardRemoteAssignmentRecord {
    let _ = offer_controller(fixture).await;
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(&fixture.request, HOST, "2026-07-19T10:00:30Z")
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    let response = RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-l1".into(),
            expires_at: LEASE_EXPIRES.into(),
        }),
        rejection_code: None,
    };
    match fixture
        .db
        .record_task_board_remote_offer_response(&response, HOST, AFTER_EXPIRY)
        .await
        .expect("record late accepted offer")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected local fallback from a late acceptance, got {other:?}"),
    }
}
