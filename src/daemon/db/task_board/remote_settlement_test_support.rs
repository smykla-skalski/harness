use sha2::{Digest, Sha256};
use sqlx::query;

use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_test_support::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactFetchRequest, RemoteArtifactManifest,
    RemoteAssignmentWireState, RemoteLease, RemoteSettledRequest, RemoteStatusResponse,
    RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome,
};

const ARTIFACT_BYTES: &[u8] = b"durable remote review artifact";
const UNKNOWN_AT: &str = "2026-07-19T10:00:30Z";

pub(super) async fn unknown_workspace_assignment(
    fixture: &ExecutorFixture,
) -> (super::TaskBoardRemoteAssignmentRecord, RemoteSettledRequest) {
    let accepted = accept_executor(fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim executor assignment");
    authorize_and_start_executor(fixture, &accepted.assignment_id, STARTED_AT).await;
    let TaskBoardRemoteMutationOutcome::Updated(unknown) = fixture
        .db
        .mark_task_board_remote_assignment_unknown(
            &fixture.request.binding,
            "worker outcome unknown",
            UNKNOWN_AT,
        )
        .await
        .expect("mark executor assignment unknown")
    else {
        panic!("unknown transition did not update assignment");
    };
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: unknown.lease_id.clone().expect("unknown lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Unknown,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal unknown settlement");
    (unknown, settlement)
}

pub(super) async fn store_and_verify_artifact(
    fixture: &ExecutorFixture,
    completed: &super::TaskBoardRemoteAssignmentRecord,
    entry: &RemoteArtifactEntry,
) -> RemoteArtifactFetchRequest {
    let stored = fixture
        .db
        .store_task_board_remote_artifact(
            &fixture.request.binding,
            completed.lease_id.as_deref().expect("lease"),
            &fixture.request.request_sha256,
            entry,
            ARTIFACT_BYTES,
            PRINCIPAL,
            "2026-07-19T10:00:45Z",
        )
        .await
        .expect("store immutable artifact");
    let replay = fixture
        .db
        .store_task_board_remote_artifact(
            &fixture.request.binding,
            completed.lease_id.as_deref().expect("lease"),
            &fixture.request.request_sha256,
            entry,
            ARTIFACT_BYTES,
            PRINCIPAL,
            "2026-07-19T10:00:49Z",
        )
        .await
        .expect("replay immutable artifact store");
    assert_eq!(replay, stored);
    let fetch = artifact_fetch(fixture, completed, entry);
    let fetched = fixture
        .db
        .task_board_remote_artifact(&fetch, PRINCIPAL)
        .await
        .expect("fetch artifact before settlement")
        .expect("artifact retained before settlement");
    assert_eq!(
        fetched
            .response(&fetch)
            .expect("artifact response")
            .validate(&fetch)
            .expect("validate artifact response"),
        ARTIFACT_BYTES
    );
    fetch
}

pub(super) async fn completed_assignment_with_artifact(
    fixture: &ExecutorFixture,
) -> (super::TaskBoardRemoteAssignmentRecord, RemoteArtifactEntry) {
    let accepted = accept_executor(fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim executor assignment");
    authorize_and_start_executor(fixture, &accepted.assignment_id, STARTED_AT).await;
    let started = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load started assignment")
        .expect("started assignment");
    let entry = RemoteArtifactEntry {
        relative_path: "result/review.json".into(),
        sha256: hex::encode(Sha256::digest(ARTIFACT_BYTES)),
        size_bytes: ARTIFACT_BYTES.len() as u64,
        media_type: "application/json".into(),
    };
    let response = completed_status(fixture, &started, entry.clone());
    let status_json = serde_json::to_string(&response).expect("serialize completed status");
    let result_sha256 = response
        .result
        .as_ref()
        .expect("completed result")
        .result_sha256
        .clone();
    query(
        "UPDATE task_board_remote_assignments
         SET state = 'completed', heartbeat_at = ?2, completed_at = ?2,
             result_json = ?3, status_sha256 = ?4, result_sha256 = ?5, updated_at = ?2
         WHERE assignment_id = ?1 AND state = 'started'",
    )
    .bind(&accepted.assignment_id)
    .bind(&response.observed_at)
    .bind(status_json)
    .bind(&response.status_sha256)
    .bind(result_sha256)
    .execute(fixture.db.pool())
    .await
    .expect("persist completed artifact manifest");
    let completed = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load completed assignment")
        .expect("completed assignment");
    (completed, entry)
}

pub(super) fn completed_settlement(
    fixture: &ExecutorFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
) -> RemoteSettledRequest {
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Completed,
        result_sha256: assignment.result_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal completed settlement")
}

fn completed_status(
    fixture: &ExecutorFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    artifact: RemoteArtifactEntry,
) -> RemoteStatusResponse {
    let exact_head_revision = fixture
        .request
        .binding
        .expected_head_revision
        .clone()
        .expect("review offer exact head");
    let result = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: fixture.request.binding.execution_id.clone(),
        action_key: fixture.request.binding.action_key.clone(),
        attempt: fixture.request.binding.attempt,
        idempotency_key: fixture.request.binding.idempotency_key.clone(),
        exact_head_revision: exact_head_revision.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: exact_head_revision,
                summary: "review passed".into(),
                findings: Vec::new(),
            },
        }),
    };
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        state: RemoteAssignmentWireState::Completed,
        offer_request_sha256: fixture.request.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: assignment.lease_id.clone().expect("lease"),
            expires_at: assignment.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: Some(
            RemoteTypedResult::seal(result, fixture.request.request_sha256.clone())
                .expect("seal typed result"),
        ),
        output_artifacts: RemoteArtifactManifest {
            entries: vec![artifact],
        },
        claimed_at: assignment.claimed_at.clone(),
        started_at: assignment.started_at.clone(),
        workspace_ref: assignment.workspace_ref.clone(),
        error_code: None,
        failure_class: None,
        observed_at: "2026-07-19T10:00:40Z".into(),
    }
    .seal()
    .expect("seal completed status")
}

fn artifact_fetch(
    fixture: &ExecutorFixture,
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    entry: &RemoteArtifactEntry,
) -> RemoteArtifactFetchRequest {
    RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        relative_path: entry.relative_path.clone(),
        expected_sha256: entry.sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact fetch")
}
