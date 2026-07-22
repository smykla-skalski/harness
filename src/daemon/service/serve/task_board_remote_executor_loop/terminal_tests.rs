use std::path::Path;

use sqlx::query_scalar;

use super::{TerminalEvidence, completed_evidence, persist_terminal_snapshot};
use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture,
    TaskBoardRemoteMutationOutcome, accept_remote_executor, authorize_and_start_remote_executor,
    remote_executor_claim_request, remote_executor_fixture,
};
use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::task_board_remote_transport::wire::{
    MAX_REMOTE_TYPED_RESULT_BYTES, RemoteAssignmentWireState,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardFailureClass, TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict,
    TaskBoardRemoteAssignmentState, TaskBoardReviewResult, TaskBoardReviewerOutcome,
};

const OWNER: &str = "instance-a";

#[tokio::test]
async fn completed_review_persists_once_and_replays_after_restart() {
    let (fixture, record, snapshot) = completed_review_fixture().await;
    let TerminalEvidence::Completed { artifacts, .. } =
        completed_evidence(&record, &snapshot, Path::new(&snapshot.project_dir))
            .await
            .expect("build terminal review evidence")
    else {
        panic!("completed review produced failed evidence");
    };

    persist_terminal_snapshot(
        &fixture.db,
        OWNER,
        &record,
        &snapshot,
        Path::new(&snapshot.project_dir),
    )
    .await
    .expect("persist terminal review evidence");
    let committed = fixture
        .db
        .task_board_remote_assignment(&record.assignment_id)
        .await
        .expect("load completed remote assignment")
        .expect("completed remote assignment");
    assert_eq!(committed.state, TaskBoardRemoteAssignmentState::Completed);
    assert_eq!(artifact_count(&fixture.db, &record.assignment_id).await, 1);
    let response = committed
        .status_response
        .clone()
        .expect("immutable completed status");
    let owner = committed
        .executor_lifecycle_owner
        .clone()
        .expect("terminal lifecycle owner");

    let database_path = fixture._temp.path().join("executor.db");
    let RemoteExecutorFixture { db, _temp, .. } = fixture;
    drop(db);
    let reopened = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("reopen executor database");
    assert!(matches!(
        reopened
            .complete_task_board_remote_executor_terminal(&owner, &response, &artifacts)
            .await
            .expect("replay terminal evidence after restart"),
        TaskBoardRemoteMutationOutcome::Replayed(ref replayed) if replayed == &committed
    ));
    assert_eq!(artifact_count(&reopened, &record.assignment_id).await, 1);
}

#[tokio::test]
async fn completed_run_without_a_result_fails_closed_without_artifacts() {
    let (fixture, record, mut snapshot) = completed_review_fixture().await;
    snapshot.final_message = None;
    fixture
        .db
        .save_codex_run(&snapshot)
        .await
        .expect("persist invalid completed run");

    persist_terminal_snapshot(
        &fixture.db,
        OWNER,
        &record,
        &snapshot,
        Path::new(&snapshot.project_dir),
    )
    .await
    .expect("persist fail-closed terminal evidence");
    let failed = fixture
        .db
        .task_board_remote_assignment(&record.assignment_id)
        .await
        .expect("load failed remote assignment")
        .expect("failed remote assignment");
    assert_eq!(failed.state, TaskBoardRemoteAssignmentState::Failed);
    let response = failed.status_response.expect("sealed failed status");
    assert_eq!(
        response.error_code.as_deref(),
        Some("executor_output_invalid")
    );
    assert_eq!(
        response.failure_class,
        Some(TaskBoardFailureClass::Permanent)
    );
    assert!(response.output_artifacts.entries.is_empty());
    assert_eq!(artifact_count(&fixture.db, &record.assignment_id).await, 0);
}

#[tokio::test]
async fn oversized_completed_result_persists_only_small_failed_evidence() {
    let (fixture, record, mut snapshot) = completed_review_fixture().await;
    let mut result = review_result(&record);
    let TaskBoardAttemptResultArtifact::Review(review) = &mut result.artifact else {
        panic!("review fixture produced another result kind");
    };
    review.result.summary = "x".repeat(MAX_REMOTE_TYPED_RESULT_BYTES + 1);
    let oversized = serde_json::to_string(&result).expect("serialize oversized local result");
    assert!(oversized.len() > MAX_REMOTE_TYPED_RESULT_BYTES);
    snapshot.final_message = Some(oversized);
    fixture
        .db
        .save_codex_run(&snapshot)
        .await
        .expect("persist oversized completed run evidence");

    persist_terminal_snapshot(
        &fixture.db,
        OWNER,
        &record,
        &snapshot,
        Path::new(&snapshot.project_dir),
    )
    .await
    .expect("persist bounded fail-closed terminal evidence");
    let failed = fixture
        .db
        .task_board_remote_assignment(&record.assignment_id)
        .await
        .expect("load oversized terminal assignment")
        .expect("oversized terminal assignment");
    assert_eq!(failed.state, TaskBoardRemoteAssignmentState::Failed);
    assert!(failed.result_sha256.is_none());
    let response = failed.status_response.expect("sealed failed status");
    assert_eq!(response.state, RemoteAssignmentWireState::Failed);
    assert!(response.result.is_none());
    assert_eq!(
        response.error_code.as_deref(),
        Some("executor_output_invalid")
    );
    assert_eq!(
        response.failure_class,
        Some(TaskBoardFailureClass::Permanent)
    );
    assert!(response.output_artifacts.entries.is_empty());
    assert!(
        serde_json::to_vec(&response)
            .expect("serialize bounded failed response")
            .len()
            < MAX_REMOTE_TYPED_RESULT_BYTES
    );
    assert_eq!(artifact_count(&fixture.db, &record.assignment_id).await, 0);
}

async fn completed_review_fixture() -> (
    RemoteExecutorFixture,
    crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    crate::daemon::protocol::CodexRunSnapshot,
) {
    let fixture = remote_executor_fixture(1).await;
    let accepted = accept_remote_executor(&fixture, &fixture.request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &remote_executor_claim_request(&fixture.request, &accepted),
                REMOTE_EXECUTOR_PRINCIPAL,
                "2026-07-19T10:00:10Z",
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    authorize_and_start_remote_executor(&fixture, &accepted.assignment_id, "2026-07-19T10:00:20Z")
        .await;
    let record = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load started executor assignment")
        .expect("started executor assignment");
    let identity = crate::daemon::db::remote_executor_identity(&record)
        .expect("deterministic executor identity");
    let mut snapshot = fixture
        .db
        .codex_run(&identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");
    snapshot.status = CodexRunStatus::Completed;
    snapshot.final_message =
        Some(serde_json::to_string(&review_result(&record)).expect("serialize review result"));
    snapshot.updated_at = "2026-07-19T10:00:30Z".into();
    fixture
        .db
        .save_codex_run(&snapshot)
        .await
        .expect("persist completed executor run");
    (fixture, record, snapshot)
}

fn review_result(
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
) -> TaskBoardLocalAttemptResult {
    let binding = &record.require_offer().expect("strict offer").binding;
    let head = binding
        .expected_head_revision
        .clone()
        .expect("review exact head");
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: head.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: head,
                summary: "reviewed remotely".into(),
                findings: Vec::new(),
            },
        }),
    }
}

async fn artifact_count(db: &AsyncDaemonDb, assignment_id: &str) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_artifacts WHERE assignment_id = ?1")
        .bind(assignment_id)
        .fetch_one(db.pool())
        .await
        .expect("count remote artifacts")
}
