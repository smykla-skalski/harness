use sha2::{Digest, Sha256};
use sqlx::query;

use super::super::completion_evidence_tests::{accepted_offer, remote_status, remote_status_request};
use super::super::remote_start_tests::{
    PreparedRemoteOffer, offer_remote, prepare_remote_offer_with_policy,
    prepare_remote_offer_with_retry,
};
use crate::daemon::db::task_board::TaskBoardRemoteMutationOutcome;
use crate::daemon::db::task_board::remote_assignment_test_support::claim_request;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAssignmentWireState, RemoteClaimResponse,
    RemoteLease, RemoteStatusResponse, RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardFailureClass, TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict,
    TaskBoardReviewResult, TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionCas,
};

const PRINCIPAL: &str = "executor-a";
pub(super) const RESULT_PATH: &str = "result/attempt.json";
const RESULT_MEDIA_TYPE: &str = "application/vnd.harness.task-board-result+json";

pub(super) struct CompletedCandidate {
    pub(super) prepared: PreparedRemoteOffer,
    pub(super) parent: crate::task_board::TaskBoardWorkflowExecutionRecord,
    pub(super) response: RemoteStatusResponse,
    pub(super) entry: RemoteArtifactEntry,
    pub(super) content: Vec<u8>,
}

pub(super) async fn completed_candidate(
    label: &str,
    mutate_bytes: Option<fn(&mut RemoteTypedResult)>,
) -> CompletedCandidate {
    let prepared = prepare_remote_offer_with_policy(label, true).await;
    offer_and_accept(&prepared).await;
    let typed = typed_review_result(&prepared);
    let mut stored = typed.clone();
    if let Some(mutate) = mutate_bytes {
        mutate(&mut stored);
    }
    let content = serde_json::to_vec(&stored).expect("serialize fetched remote result");
    let entry = result_entry(&content);
    let mut response = remote_status(&prepared.offer, RemoteAssignmentWireState::Running, true);
    response.state = RemoteAssignmentWireState::Completed;
    response.result = Some(typed);
    response.output_artifacts = RemoteArtifactManifest {
        entries: vec![entry.clone()],
    };
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.status_sha256.clear();
    response = response.seal().expect("seal provisional completed status");
    record_terminal_status(&prepared, &response).await;
    let parent = load_parent(&prepared).await;
    CompletedCandidate {
        prepared,
        parent,
        response,
        entry,
        content,
    }
}

pub(super) async fn failed_candidate(
    label: &str,
    failure_class: TaskBoardFailureClass,
    max_attempts: Option<u32>,
) -> CompletedCandidate {
    let prepared = prepare_remote_offer_with_retry(label, true, max_attempts).await;
    offer_and_accept(&prepared).await;
    let mut response = remote_status(&prepared.offer, RemoteAssignmentWireState::Running, true);
    response.state = RemoteAssignmentWireState::Failed;
    response.error_code = Some("remote_execution_failed".into());
    response.failure_class = Some(failure_class);
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.status_sha256.clear();
    response = response.seal().expect("seal provisional failed status");
    record_terminal_status(&prepared, &response).await;
    let parent = load_parent(&prepared).await;
    CompletedCandidate {
        prepared,
        parent,
        response,
        entry: result_entry(&[]),
        content: Vec::new(),
    }
}

async fn offer_and_accept(prepared: &PreparedRemoteOffer) {
    offer_remote(prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
        .await
        .expect("offer remote assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            PRINCIPAL,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            PRINCIPAL,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    let assignment = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load accepted assignment")
        .expect("accepted assignment");
    let claim = claim_request(&prepared.offer, &assignment);
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(&claim, PRINCIPAL, "2026-07-19T10:00:02Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    // Record the executor's claim response so the controller settles the claim I/O
    // authority the same way the live path does; the terminal adoption target is
    // then authority-free.
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
            PRINCIPAL,
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("record remote claim response");
}

async fn record_terminal_status(prepared: &PreparedRemoteOffer, response: &RemoteStatusResponse) {
    assert!(matches!(
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                response,
                PRINCIPAL,
            )
            .await
            .expect("record provisional terminal status"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

pub(super) async fn store_result(candidate: &CompletedCandidate) {
    let assignment = candidate
        .prepared
        .db
        .task_board_remote_assignment(&candidate.prepared.offer.binding.assignment_id)
        .await
        .expect("load terminal assignment")
        .expect("terminal assignment");
    candidate
        .prepared
        .db
        .store_task_board_remote_artifact(
            &candidate.prepared.offer.binding,
            assignment.lease_id.as_deref().expect("assignment lease"),
            &candidate.prepared.offer.request_sha256,
            &candidate.entry,
            &candidate.content,
            PRINCIPAL,
            "2026-07-19T10:00:06Z",
        )
        .await
        .expect("store fetched remote result");
}

pub(super) async fn assert_adoption_rejected_unchanged(candidate: &CompletedCandidate) {
    candidate
        .prepared
        .db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect_err("invalid fetched evidence must fail closed");
    assert_eq!(load_parent(&candidate.prepared).await, candidate.parent);
}

pub(super) async fn insert_extra_artifact(candidate: &CompletedCandidate) {
    let assignment = candidate
        .prepared
        .db
        .task_board_remote_assignment(&candidate.prepared.offer.binding.assignment_id)
        .await
        .expect("load terminal assignment")
        .expect("terminal assignment");
    let content = b"extra";
    query(
        "INSERT INTO task_board_remote_artifacts (
           assignment_id, fencing_epoch, lease_id, offer_request_sha256,
           authenticated_principal, relative_path, sha256, size_bytes, media_type,
           content, stored_at
         ) VALUES (?1, 1, ?2, ?3, ?4, 'result/extra.txt', ?5, 5,
                   'text/plain', ?6, '2026-07-19T10:00:06Z')",
    )
    .bind(&candidate.prepared.offer.binding.assignment_id)
    .bind(assignment.lease_id.expect("lease"))
    .bind(&candidate.prepared.offer.request_sha256)
    .bind(PRINCIPAL)
    .bind(hex::encode(Sha256::digest(content)))
    .bind(content.as_slice())
    .execute(candidate.prepared.db.pool())
    .await
    .expect("insert unexpected fetched artifact");
}

fn typed_review_result(prepared: &PreparedRemoteOffer) -> RemoteTypedResult {
    let result = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: prepared.offer.binding.execution_id.clone(),
        action_key: prepared.offer.binding.action_key.clone(),
        attempt: prepared.offer.binding.attempt,
        idempotency_key: prepared.offer.binding.idempotency_key.clone(),
        exact_head_revision: prepared
            .offer
            .binding
            .expected_head_revision
            .clone()
            .expect("review exact head"),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "default-code-reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: prepared
                    .offer
                    .binding
                    .expected_head_revision
                    .clone()
                    .expect("review exact head"),
                summary: "remote review passed".into(),
                findings: Vec::new(),
            },
        }),
    };
    RemoteTypedResult::seal(result, prepared.offer.request_sha256.clone())
        .expect("seal typed result")
}

fn result_entry(content: &[u8]) -> RemoteArtifactEntry {
    RemoteArtifactEntry {
        relative_path: RESULT_PATH.into(),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: u64::try_from(content.len()).expect("result size"),
        media_type: RESULT_MEDIA_TYPE.into(),
    }
}

pub(super) async fn load_parent(
    prepared: &PreparedRemoteOffer,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    prepared
        .db
        .task_board_workflow_execution(&prepared.execution_id)
        .await
        .expect("load workflow execution")
        .expect("workflow execution")
}

pub(super) fn wrong_schema(result: &mut RemoteTypedResult) {
    result.result.schema_version += 1;
}

pub(super) fn wrong_action(result: &mut RemoteTypedResult) {
    result.result.action_key = "review:other".into();
}

pub(super) fn wrong_attempt(result: &mut RemoteTypedResult) {
    result.result.attempt += 1;
}

pub(super) fn wrong_profile(result: &mut RemoteTypedResult) {
    if let TaskBoardAttemptResultArtifact::Review(outcome) = &mut result.result.artifact {
        outcome.profile_id = "other".into();
    }
}

pub(super) fn wrong_head(result: &mut RemoteTypedResult) {
    result.result.exact_head_revision = "f".repeat(40);
}
