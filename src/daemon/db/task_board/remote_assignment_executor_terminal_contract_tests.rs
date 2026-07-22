use sqlx::query_scalar;

use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_executor_terminal_test_support::*;
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState};

#[tokio::test]
async fn completed_review_rejects_missing_extra_wrong_path_and_tampered_bytes() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Review).await;
    let (response, artifacts) = completed_evidence(&terminal.record);

    let mut missing = response.clone();
    missing.output_artifacts.entries.clear();
    missing = missing.seal().expect("seal missing-artifact response");
    assert_rejected_without_artifacts(&terminal, &missing, &[]).await;

    let mut extra_artifacts = artifacts.clone();
    extra_artifacts.push(terminal_artifact(
        "result/extra.txt",
        "text/plain",
        b"extra".to_vec(),
    ));
    let mut extra = response.clone();
    extra.output_artifacts.entries = extra_artifacts
        .iter()
        .map(|artifact| artifact.entry.clone())
        .collect();
    extra = extra.seal().expect("seal extra-artifact response");
    assert_rejected_without_artifacts(&terminal, &extra, &extra_artifacts).await;

    let mut wrong_path_artifacts = artifacts.clone();
    wrong_path_artifacts[0].entry.relative_path = "result/not-canonical.json".into();
    let mut wrong_path = response.clone();
    wrong_path.output_artifacts.entries = wrong_path_artifacts
        .iter()
        .map(|artifact| artifact.entry.clone())
        .collect();
    wrong_path = wrong_path.seal().expect("seal wrong-path response");
    assert_rejected_without_artifacts(&terminal, &wrong_path, &wrong_path_artifacts).await;

    let mut tampered = artifacts.clone();
    tampered[0].content.push(b'!');
    assert_rejected_without_artifacts(&terminal, &response, &tampered).await;

    assert!(matches!(
        terminal
            .fixture
            .db
            .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts,)
            .await
            .expect("valid review terminal"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

#[tokio::test]
async fn implementation_requires_and_atomically_persists_the_exact_git_bundle() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Implementation).await;
    let (response, artifacts) = completed_evidence(&terminal.record);
    assert_eq!(artifacts.len(), 2);

    let mut missing_bundle = response.clone();
    missing_bundle.output_artifacts.entries.pop();
    missing_bundle = missing_bundle.seal().expect("seal missing bundle response");
    assert_rejected_without_artifacts(&terminal, &missing_bundle, &artifacts[..1]).await;

    let mut invalid_bundle = artifacts.clone();
    invalid_bundle[1] = terminal_artifact(
        "result/implementation.bundle",
        "application/x-git-bundle",
        b"not a git bundle".to_vec(),
    );
    let mut invalid = response.clone();
    invalid.output_artifacts.entries = invalid_bundle
        .iter()
        .map(|artifact| artifact.entry.clone())
        .collect();
    invalid = invalid.seal().expect("seal invalid bundle response");
    assert_rejected_without_artifacts(&terminal, &invalid, &invalid_bundle).await;

    let outcome = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts)
        .await
        .expect("commit implementation terminal");
    assert!(matches!(
        outcome,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Completed
    ));
    assert_eq!(artifact_count(&terminal).await, 2);
}

#[tokio::test]
async fn completed_evaluate_requires_only_the_canonical_result_artifact() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Evaluate).await;
    let (response, artifacts) = completed_evidence(&terminal.record);
    assert_eq!(artifacts.len(), 1);

    let outcome = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts)
        .await
        .expect("commit evaluate terminal");
    assert!(matches!(
        outcome,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Completed
    ));
    assert_eq!(artifact_count(&terminal).await, 1);
    assert!(matches!(
        terminal
            .fixture
            .db
            .complete_task_board_remote_executor_terminal(
                &terminal.owner,
                &response,
                &artifacts,
            )
            .await
            .expect("replay evaluate terminal"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
}

#[tokio::test]
async fn failed_terminal_has_no_output_artifacts_and_replays_exactly() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Review).await;
    let response = failed_evidence(&terminal.record);
    let outcome = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &[])
        .await
        .expect("commit failed terminal");
    let TaskBoardRemoteMutationOutcome::Updated(record) = outcome else {
        panic!("expected failed terminal update, got {outcome:?}");
    };
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Failed);
    assert_eq!(
        record.executor_lifecycle_owner.as_ref(),
        Some(&terminal.owner)
    );
    assert_eq!(artifact_count(&terminal).await, 0);
    assert!(matches!(
        terminal
            .fixture
            .db
            .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &[])
            .await
            .expect("replay failed terminal"),
        TaskBoardRemoteMutationOutcome::Replayed(ref replayed) if replayed == &record
    ));
}

async fn assert_rejected_without_artifacts(
    terminal: &TerminalExecutor,
    response: &crate::daemon::task_board_remote_transport::wire::RemoteStatusResponse,
    artifacts: &[super::TaskBoardRemoteTerminalArtifact],
) {
    terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, response, artifacts)
        .await
        .expect_err("invalid terminal evidence must fail closed");
    assert_eq!(artifact_count(terminal).await, 0);
    let record = terminal
        .fixture
        .db
        .task_board_remote_assignment(&terminal.record.assignment_id)
        .await
        .expect("load unchanged terminal candidate")
        .expect("terminal candidate exists");
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Started);
    assert!(record.status_response.is_none());
}

async fn artifact_count(terminal: &TerminalExecutor) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = ?2",
    )
    .bind(&terminal.record.assignment_id)
    .bind(i64::try_from(terminal.record.fencing_epoch).expect("fencing epoch"))
    .fetch_one(terminal.fixture.db.pool())
    .await
    .expect("count terminal artifacts")
}
