use chrono::{Duration, SecondsFormat, Utc};

use super::controller_authority_test_support::HOST_ID;
use super::wire::{
    RemoteClaimRequest, RemoteClaimResponse, RemoteLease, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferResponse, RemoteStatusRequest,
    RemoteStatusResponse, RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::db::{PreparedRemoteOffer, TaskBoardRemoteOfferOutcome, prepare_remote_offer};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionHostAdvertisement, TaskBoardFailureClass, TaskBoardLocalAttemptResult,
    TaskBoardPhaseCapabilityProfile, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionCas,
};

pub(super) struct PreparedLifecycle {
    pub(super) prepared: PreparedRemoteOffer,
    pub(super) times: LifecycleTimes,
}

pub(super) struct LifecycleTimes {
    pub(super) offered_at: String,
    pub(super) before_expiry: String,
    pub(super) l1_expires_at: String,
    pub(super) started_at: String,
    pub(super) status_observed_at: String,
    pub(super) after_expiry: String,
    pub(super) l2_expires_at: String,
}

pub(super) async fn prepared_acceptance(item_id: &str) -> PreparedLifecycle {
    let mut prepared = prepare_remote_offer(item_id).await;
    let now = Utc::now();
    let times = LifecycleTimes {
        offered_at: canonical_time(now),
        before_expiry: canonical_time(now + Duration::seconds(30)),
        l1_expires_at: canonical_time(now + Duration::seconds(60)),
        started_at: canonical_time(now + Duration::seconds(31)),
        status_observed_at: canonical_time(now + Duration::seconds(45)),
        after_expiry: canonical_time(now + Duration::seconds(61)),
        l2_expires_at: canonical_time(now + Duration::seconds(120)),
    };
    prepared.offer.deadline_at = canonical_time(now + Duration::minutes(10));
    prepared.offer = prepared.offer.clone().seal().expect("reseal current offer");
    refresh_host(&prepared, &times.offered_at).await;
    let offered = prepared
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
            &TaskBoardExecutionAttemptCas::from(&prepared.attempt),
            &prepared.offer,
            HOST_ID,
            &times.offered_at,
            &times.l1_expires_at,
            &prepared.offer.deadline_at,
        )
        .await
        .expect("persist truthful remote offer");
    assert!(matches!(offered, TaskBoardRemoteOfferOutcome::Created(_)));
    assert!(prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            HOST_ID,
            &times.offered_at,
        )
        .await
        .expect("claim offer authority")
        .is_some());
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared, &times),
            HOST_ID,
            &times.offered_at,
        )
        .await
        .expect("persist accepted offer");
    PreparedLifecycle { prepared, times }
}

pub(super) async fn persist_claim(state: &PreparedLifecycle) {
    let request = claim_request(state);
    assert!(
        state
            .prepared
            .db
            .claim_task_board_remote_claim_io_authority(
                &request,
                HOST_ID,
                &state.times.before_expiry,
            )
            .await
            .expect("claim claim authority")
            .is_some()
    );
    state
        .prepared
        .db
        .record_task_board_remote_assignment_claim(
            &request,
            &claim_response(state),
            HOST_ID,
            &state.times.before_expiry,
        )
        .await
        .expect("persist claimed state");
}

pub(super) fn claim_request(state: &PreparedLifecycle) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim")
}

pub(super) fn claim_response(state: &PreparedLifecycle) -> RemoteClaimResponse {
    RemoteClaimResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-admission".into(),
            expires_at: state.times.l1_expires_at.clone(),
        },
        claimed_at: state.times.before_expiry.clone(),
    }
}

pub(super) fn renewal_request(state: &PreparedLifecycle) -> RemoteLeaseRenewRequest {
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal")
}

pub(super) fn renewal_response(state: &PreparedLifecycle) -> RemoteLeaseRenewResponse {
    RemoteLeaseRenewResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        lease: RemoteLease {
            lease_id: "lease-l2".into(),
            expires_at: state.times.l2_expires_at.clone(),
        },
    }
}

pub(super) fn status_request(state: &PreparedLifecycle) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status")
}

pub(super) fn completed_status(state: &PreparedLifecycle) -> RemoteStatusResponse {
    let head = state
        .prepared
        .offer
        .binding
        .expected_head_revision
        .clone()
        .expect("review exact head");
    let profile_id = state
        .prepared
        .execution
        .resolved_reviewers
        .profiles
        .first()
        .expect("resolved reviewer")
        .id
        .clone();
    let result = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: state.prepared.offer.binding.execution_id.clone(),
        action_key: state.prepared.offer.binding.action_key.clone(),
        attempt: state.prepared.offer.binding.attempt,
        idempotency_key: state.prepared.offer.binding.idempotency_key.clone(),
        exact_head_revision: head.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id,
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: head,
                summary: "remote review passed".into(),
                findings: Vec::new(),
            },
        }),
    };
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        state: super::wire::RemoteAssignmentWireState::Completed,
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: "lease-admission".into(),
            expires_at: state.times.l1_expires_at.clone(),
        }),
        result: Some(
            RemoteTypedResult::seal(result, state.prepared.offer.request_sha256.clone())
                .expect("seal typed remote review"),
        ),
        output_artifacts: super::wire::RemoteArtifactManifest::default(),
        claimed_at: Some(state.times.before_expiry.clone()),
        started_at: Some(state.times.started_at.clone()),
        workspace_ref: Some("workspace-assignment-admission".into()),
        error_code: None,
        failure_class: None,
        observed_at: state.times.status_observed_at.clone(),
    }
    .seal()
    .expect("seal completed status")
}

pub(super) fn failed_status(
    state: &PreparedLifecycle,
    failure_class: TaskBoardFailureClass,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: state.prepared.offer.binding.clone(),
        state: super::wire::RemoteAssignmentWireState::Failed,
        offer_request_sha256: state.prepared.offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: "lease-admission".into(),
            expires_at: state.times.l1_expires_at.clone(),
        }),
        result: None,
        output_artifacts: super::wire::RemoteArtifactManifest::default(),
        claimed_at: Some(state.times.before_expiry.clone()),
        started_at: Some(state.times.started_at.clone()),
        workspace_ref: Some("workspace-assignment-admission".into()),
        error_code: Some("worker_failed".into()),
        failure_class: Some(failure_class),
        observed_at: state.times.status_observed_at.clone(),
    }
    .seal()
    .expect("seal failed status")
}

fn accepted_offer(prepared: &PreparedRemoteOffer, times: &LifecycleTimes) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: prepared.offer.binding.clone(),
        offer_request_sha256: prepared.offer.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-admission".into(),
            expires_at: times.l1_expires_at.clone(),
        }),
        rejection_code: None,
    }
}

async fn refresh_host(prepared: &PreparedRemoteOffer, observed_at: &str) {
    prepared
        .db
        .record_task_board_execution_host_observation(
            &TaskBoardExecutionHostAdvertisement {
                host_id: HOST_ID.into(),
                host_instance_id: "instance-a".into(),
                protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
                repositories: vec!["example/harness".into()],
                runtimes: vec!["codex".into()],
                capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
                capacity: 1,
                active_assignments: 0,
                heartbeat_at: observed_at.into(),
            },
            observed_at,
        )
        .await
        .expect("refresh truthful host observation");
}

fn canonical_time(time: chrono::DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Secs, true)
}
