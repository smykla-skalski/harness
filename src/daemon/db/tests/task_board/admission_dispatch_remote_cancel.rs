use super::completion_evidence_tests::{accepted_offer, intent_status};
use super::ledger_kind_state;
use super::remote_start_tests::{
    PreparedRemoteOffer, offer_remote, prepare_remote_offer_with_policy,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLease, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardExecutionState, TaskBoardRemoteAssignmentState,
};

#[tokio::test]
async fn cancel_adopts_unreported_start_evidence_and_accounts_exactly_once() {
    let prepared = prepare_remote_offer_with_policy("admission-cancel-started", true).await;
    accept_prepared_offer(&prepared).await;
    let request = cancel_request(&prepared);
    prepared
        .db
        .claim_task_board_remote_cancel_io_authority(&request, "executor-a", "2026-07-19T10:00:02Z")
        .await
        .expect("claim cancel authority")
        .expect("assignment remains cancellable");
    let response = cancel_response(
        &request,
        Some("2026-07-19T10:00:02Z"),
        Some("2026-07-19T10:00:03Z"),
        Some("workspace-cancel"),
    );
    prepared
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            "executor-a",
            "2026-07-19T10:00:06Z",
        )
        .await
        .expect("record cancel with unreported start evidence");

    let assignment = load_assignment(&prepared).await;
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Cancelled);
    assert_eq!(
        assignment.claimed_at.as_deref(),
        response.claimed_at.as_deref()
    );
    assert_eq!(
        assignment.started_at.as_deref(),
        response.started_at.as_deref()
    );
    assert_eq!(
        assignment.workspace_ref.as_deref(),
        response.workspace_ref.as_deref()
    );
    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "completed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "released"
    );
    let execution = prepared
        .db
        .task_board_workflow_execution(&prepared.execution_id)
        .await
        .expect("load cancelled execution")
        .expect("cancelled execution");
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Cancelled
    );
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE),
        Some(&format!("remote:{}", prepared.offer.binding.assignment_id))
    );
    let sequence = prepared
        .db
        .current_change_sequence()
        .await
        .expect("load terminal sequence");
    prepared
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            "executor-a",
            "2026-07-19T10:00:07Z",
        )
        .await
        .expect("replay exact cancel response");
    assert_eq!(
        prepared
            .db
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "committed"
    );
}

#[tokio::test]
async fn empty_cancel_response_preserves_claim_and_releases_uncharged_reservation() {
    let prepared = prepare_remote_offer_with_policy("admission-cancel-claimed", true).await;
    let accepted = accept_prepared_offer(&prepared).await;
    let claim = RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: prepared.offer.binding.clone(),
        lease_id: accepted.lease_id.clone().expect("accepted lease"),
        offer_request_sha256: prepared.offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim request");
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(&claim, "executor-a", "2026-07-19T10:00:02Z")
        .await
        .expect("claim claim authority")
        .expect("claim remains active");
    prepared
        .db
        .record_task_board_remote_assignment_claim(
            &claim,
            &RemoteClaimResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: prepared.offer.binding.clone(),
                offer_request_sha256: prepared.offer.request_sha256.clone(),
                lease: RemoteLease {
                    lease_id: claim.lease_id.clone(),
                    expires_at: "2026-07-19T10:01:00Z".into(),
                },
                claimed_at: "2026-07-19T10:00:02Z".into(),
            },
            "executor-a",
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("record controller claim");
    let request = cancel_request(&prepared);
    prepared
        .db
        .claim_task_board_remote_cancel_io_authority(&request, "executor-a", "2026-07-19T10:00:03Z")
        .await
        .expect("claim cancel authority")
        .expect("claimed assignment remains cancellable");
    let response = cancel_response(&request, None, None, None);
    prepared
        .db
        .record_task_board_remote_assignment_cancel(
            &request,
            &response,
            "executor-a",
            "2026-07-19T10:00:05Z",
        )
        .await
        .expect("record empty cancel evidence");
    let assignment = load_assignment(&prepared).await;
    assert_eq!(
        assignment.claimed_at.as_deref(),
        Some("2026-07-19T10:00:02Z")
    );
    assert_eq!(assignment.started_at, None);
    assert_eq!(assignment.workspace_ref, None);
    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "failed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "released"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "released"
    );
}

async fn accept_prepared_offer(
    prepared: &PreparedRemoteOffer,
) -> crate::daemon::db::task_board::TaskBoardRemoteAssignmentRecord {
    offer_remote(prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
        .await
        .expect("offer remote assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    match prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer")
    {
        crate::daemon::db::task_board::TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected accepted assignment, got {other:?}"),
    }
}

fn cancel_request(prepared: &PreparedRemoteOffer) -> RemoteCancelRequest {
    RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: prepared.offer.request_sha256.clone(),
        reason: "operator requested cancellation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal cancel request")
}

fn cancel_response(
    request: &RemoteCancelRequest,
    claimed_at: Option<&str>,
    started_at: Option<&str>,
    workspace_ref: Option<&str>,
) -> RemoteCancelResponse {
    RemoteCancelResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        cancel_response_sha256: String::new(),
        state: RemoteAssignmentWireState::Cancelled,
        claimed_at: claimed_at.map(str::to_owned),
        started_at: started_at.map(str::to_owned),
        workspace_ref: workspace_ref.map(str::to_owned),
        observed_at: "2026-07-19T10:00:05Z".into(),
    }
    .seal(request)
    .expect("seal cancel response")
}

async fn load_assignment(
    prepared: &PreparedRemoteOffer,
) -> crate::daemon::db::task_board::TaskBoardRemoteAssignmentRecord {
    prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load assignment")
        .expect("assignment")
}
