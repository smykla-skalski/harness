use sqlx::{query, query_scalar};

use super::remote_assignment_executor_terminal_test_support::*;
use super::{TaskBoardRemoteMutationOutcome, remote_assignment_test_support::PRINCIPAL};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactFetchRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState};

#[tokio::test]
async fn terminal_artifacts_and_status_commit_once_under_the_exact_owner() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Review).await;
    let (response, artifacts) = completed_evidence(&terminal.record);
    let outcome = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts)
        .await
        .expect("commit executor terminal evidence");
    let TaskBoardRemoteMutationOutcome::Updated(record) = outcome else {
        panic!("expected terminal update, got {outcome:?}");
    };
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Completed);
    assert_eq!(record.status_response.as_ref(), Some(&response));
    assert_eq!(
        record.executor_lifecycle_owner.as_ref(),
        Some(&terminal.owner)
    );

    let fetched = terminal
        .fixture
        .db
        .task_board_remote_artifact(&artifact_request(&record, &artifacts[0]), PRINCIPAL)
        .await
        .expect("fetch sealed result artifact")
        .expect("stored result artifact");
    assert_eq!(fetched.content, artifacts[0].content);
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
            .expect("replay terminal evidence"),
        TaskBoardRemoteMutationOutcome::Replayed(ref replayed) if replayed == &record
    ));
}

#[tokio::test]
async fn conflicting_terminal_owner_status_or_bytes_are_stale_without_mutation() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Review).await;
    let (response, artifacts) = completed_evidence(&terminal.record);
    let TaskBoardRemoteMutationOutcome::Updated(committed) = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts)
        .await
        .expect("commit executor terminal evidence")
    else {
        panic!("terminal update")
    };

    let mut wrong_owner = terminal.owner.clone();
    wrong_owner.owner_epoch += 1;
    let mut wrong_status = response.clone();
    wrong_status.observed_at = "2026-07-19T10:00:31Z".into();
    wrong_status = wrong_status.seal().expect("reseal changed status");
    let mut wrong_bytes = artifacts.clone();
    wrong_bytes[0].content.push(b'!');
    for (owner, status, bytes) in [
        (&wrong_owner, &response, artifacts.as_slice()),
        (&terminal.owner, &wrong_status, artifacts.as_slice()),
        (&terminal.owner, &response, wrong_bytes.as_slice()),
    ] {
        assert!(matches!(
            terminal
                .fixture
                .db
                .complete_task_board_remote_executor_terminal(owner, status, bytes)
                .await
                .expect("conflicting replay is stale"),
            TaskBoardRemoteMutationOutcome::Stale(ref record) if record == &committed
        ));
    }
    assert_eq!(artifact_count(&terminal).await, 1);
}

#[tokio::test]
async fn terminal_update_failure_rolls_back_every_artifact_byte() {
    let terminal = terminal_executor(TaskBoardExecutionPhase::Review).await;
    let (response, artifacts) = completed_evidence(&terminal.record);
    query(
        "CREATE TRIGGER inject_remote_terminal_failure
         BEFORE UPDATE OF state ON task_board_remote_assignments
         WHEN NEW.assignment_id = OLD.assignment_id AND NEW.state = 'completed'
         BEGIN SELECT RAISE(ABORT, 'injected terminal failure'); END",
    )
    .execute(terminal.fixture.db.pool())
    .await
    .expect("install terminal failure trigger");
    let error = terminal
        .fixture
        .db
        .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts)
        .await
        .expect_err("terminal update must roll back");
    assert!(error.to_string().contains("injected terminal failure"));
    assert_eq!(artifact_count(&terminal).await, 0);
    let record = terminal
        .fixture
        .db
        .task_board_remote_assignment(&terminal.record.assignment_id)
        .await
        .expect("load rolled-back assignment")
        .expect("assignment remains");
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Started);
    assert!(record.status_response.is_none());

    query("DROP TRIGGER inject_remote_terminal_failure")
        .execute(terminal.fixture.db.pool())
        .await
        .expect("remove terminal failure trigger");
    assert!(matches!(
        terminal
            .fixture
            .db
            .complete_task_board_remote_executor_terminal(&terminal.owner, &response, &artifacts,)
            .await
            .expect("retry terminal transaction"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

fn artifact_request(
    record: &super::TaskBoardRemoteAssignmentRecord,
    artifact: &super::TaskBoardRemoteTerminalArtifact,
) -> RemoteArtifactFetchRequest {
    let offer = record.require_offer().expect("strict offer");
    RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("artifact lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        relative_path: artifact.entry.relative_path.clone(),
        expected_sha256: artifact.entry.sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal artifact fetch")
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
