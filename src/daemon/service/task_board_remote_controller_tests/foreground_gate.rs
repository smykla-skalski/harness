use chrono::{Duration, Utc};

use crate::daemon::db::{
    TaskBoardRemoteControllerScanStep, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
    remote_controller_fixture,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLease, RemoteOfferDisposition, RemoteOfferResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::CliErrorKind;
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

const OFFERED_AT: &str = "2026-07-19T10:00:00Z";
const CLAIMED_AT: &str = "2026-07-19T10:00:05Z";
const LEASE_EXPIRES_AT: &str = "2026-07-19T10:01:00Z";
const TERMINAL_AT: &str = "2026-07-19T10:00:10Z";

#[tokio::test]
async fn offline_terminal_cleanup_retry_does_not_block_foreground_driver() {
    let fixture = remote_controller_fixture(1).await;
    let accepted = accept_remote_assignment(&fixture).await;
    // Claim before cancelling so the cleanup-pending generation is a genuine capacity
    // owner; a never-claimed generation releases its slot without a cleanup handshake.
    let claimed = claim_remote_assignment(&fixture, &accepted).await;
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: claimed.lease_id.expect("claimed lease"),
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
        claimed_at: Some(CLAIMED_AT.into()),
        started_at: None,
        workspace_ref: None,
        observed_at: TERMINAL_AT.into(),
    }
    .seal(&cancel)
    .expect("seal terminal handoff cancellation response");
    let host_id = fixture.request.binding.host_id.as_str();
    fixture
        .db
        .claim_task_board_remote_cancel_io_authority(&cancel, host_id, TERMINAL_AT)
        .await
        .expect("claim terminal handoff cancellation")
        .expect("terminal handoff cancellation remains active");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_cancel(&cancel, &response, host_id, TERMINAL_AT)
            .await
            .expect("persist terminal projection handoff"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    disable_fixture_host(&fixture).await;

    let scan_at = super::super::canonical_now();
    let step = fixture
        .db
        .next_task_board_remote_controller_assignment(&scan_at)
        .await
        .expect("scan terminal cleanup retry")
        .expect("terminal cleanup remains scan-visible");
    let TaskBoardRemoteControllerScanStep::Assignment(item) = step else {
        panic!("terminal cleanup retry was unexpectedly quarantined");
    };
    let mut report = super::super::TaskBoardRemoteControllerReport::default();
    super::super::scan::finish_progress_attempt(
        &fixture.db,
        &item,
        Err(CliErrorKind::workflow_io("executor is offline").into()),
        &mut report,
    )
    .await
    .expect("defer offline terminal cleanup retry");
    assert!(report.scan_blocked);

    super::super::drive_task_board_remote_controller_before_local_work(&fixture.db)
        .await
        .expect("terminal cleanup retry does not block unrelated local work");
    let durable = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load terminal cleanup assignment")
        .expect("terminal cleanup assignment remains durable");
    assert_eq!(durable.state, crate::task_board::TaskBoardRemoteAssignmentState::Cancelled);
    assert!(durable.cleanup_completed_at.is_none());
    assert_eq!(
        fixture
            .db
            .task_board_remote_host_active_assignment_count_for_test(host_id)
            .await
            .expect("count cleanup-pending capacity owner"),
        1
    );
    let retry_at =
        (Utc::now() + Duration::seconds(10)).to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    assert!(matches!(
        fixture
            .db
            .next_task_board_remote_controller_assignment(&retry_at)
            .await
            .expect("rescan terminal cleanup after backoff"),
        Some(TaskBoardRemoteControllerScanStep::Assignment(_))
    ));
}

#[tokio::test]
async fn active_unhanded_off_quarantine_does_not_block_unrelated_local_work() {
    let fixture = remote_controller_fixture(1).await;
    let _accepted = accept_remote_assignment(&fixture).await;
    disable_fixture_host(&fixture).await;

    let scan_at = super::super::canonical_now();
    let step = fixture
        .db
        .next_task_board_remote_controller_assignment(&scan_at)
        .await
        .expect("scan active assignment")
        .expect("active assignment remains scan-visible");
    let TaskBoardRemoteControllerScanStep::Assignment(item) = step else {
        panic!("active assignment was unexpectedly quarantined before progression");
    };
    let mut report = super::super::TaskBoardRemoteControllerReport::default();
    super::super::scan::finish_progress_attempt(
        &fixture.db,
        &item,
        Err(CliErrorKind::workflow_io("executor is offline").into()),
        &mut report,
    )
    .await
    .expect("defer offline active assignment");
    assert!(report.scan_blocked);

    // The active, un-handed-off assignment is genuinely unverified, so the global signal
    // fires - but that must fence only its own execution (via active_remote_assignment),
    // never halt the whole foreground driver and every unrelated local write.
    assert!(
        fixture
            .db
            .task_board_remote_controller_progression_is_blocked()
            .await
            .expect("load global progression signal")
    );
    assert!(
        fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load per-execution fence"),
        "the affected execution stays fenced by its own active remote assignment"
    );
    super::super::drive_task_board_remote_controller_before_local_work(&fixture.db)
        .await
        .expect("an unverified assignment must not block unrelated local work");
}

async fn accept_remote_assignment(
    fixture: &crate::daemon::db::RemoteControllerFixture,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    assert!(matches!(
        fixture
            .db
            .offer_task_board_remote_assignment(
                &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                &fixture.request,
                &fixture.request.binding.host_id,
                OFFERED_AT,
                LEASE_EXPIRES_AT,
                &fixture.request.deadline_at,
            )
            .await
            .expect("offer terminal cleanup assignment"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(
            &fixture.request,
            &fixture.request.binding.host_id,
            OFFERED_AT,
        )
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    let response = RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-terminal-cleanup".into(),
            expires_at: LEASE_EXPIRES_AT.into(),
        }),
        rejection_code: None,
    };
    match fixture
        .db
        .record_task_board_remote_offer_response(
            &response,
            &fixture.request.binding.host_id,
            OFFERED_AT,
        )
        .await
        .expect("persist accepted terminal cleanup offer")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected accepted terminal cleanup offer, got {other:?}"),
    }
}

async fn claim_remote_assignment(
    fixture: &crate::daemon::db::RemoteControllerFixture,
    accepted: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    let host_id = fixture.request.binding.host_id.as_str();
    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal terminal cleanup claim");
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&claim, host_id, CLAIMED_AT)
        .await
        .expect("claim terminal cleanup claim authority")
        .expect("terminal cleanup claim remains active");
    let response = RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: claim.lease_id.clone(),
            expires_at: LEASE_EXPIRES_AT.into(),
        },
        claimed_at: CLAIMED_AT.into(),
    };
    match fixture
        .db
        .record_task_board_remote_assignment_claim(&claim, &response, host_id, CLAIMED_AT)
        .await
        .expect("persist terminal cleanup claim")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected claimed terminal cleanup assignment, got {other:?}"),
    }
}

async fn disable_fixture_host(fixture: &crate::daemon::db::RemoteControllerFixture) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    settings.execution_hosts[0].enabled = false;
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable terminal cleanup host");
}
