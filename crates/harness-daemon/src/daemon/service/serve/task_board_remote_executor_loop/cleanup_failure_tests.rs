use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::task_board_remote_transport::wire::RemoteAssignmentWireState;
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};

use super::super::disabled_tests::executor_state;
use super::super::reconcile_remote_executor_assignment;
use super::require_unadopted_stop_cleanup;
use super::tests::{SETTLED_AT, STARTED_AT, active_count};
use super::unadopted_tests::{
    claimed_executor_workspace, failed_at_claimed_status, load_assignment, run_deep_cleanup_async,
    terminal_settlement, with_isolated_sessions,
};

#[test]
fn failed_at_claimed_cleanup_requires_a_validated_receipt() {
    run_deep_cleanup_async(failed_at_claimed_cleanup_requires_a_validated_receipt_body);
}

async fn failed_at_claimed_cleanup_requires_a_validated_receipt_body() {
    with_isolated_sessions("remote-failed-at-claimed-cleanup", async {
        let (fixture, claimed, authority, _identity, workspace) =
            claimed_executor_workspace().await;
        let permit = fixture
            .db
            .claim_task_board_remote_executor_start_io_permit(&authority, &workspace, STARTED_AT)
            .await
            .expect("claim exact Start I/O permit")
            .expect_acquired("Start I/O remains permitted");
        let response = failed_at_claimed_status(
            &claimed,
            "remote_start_interrupted_without_run",
            TaskBoardFailureClass::Transient,
        );
        let TaskBoardRemoteMutationOutcome::Updated(failed) = fixture
            .db
            .fail_task_board_remote_executor_start_without_run(&permit, &response)
            .await
            .expect("seal no-run Start failure")
        else {
            panic!("no-run Start failure did not settle Failed");
        };
        assert!(failed.start_failure_receipt.is_some());
        let raw_failed = TaskBoardRemoteAssignmentRecord {
            start_failure_receipt: None,
            executor_start_failure_receipt_json: None,
            executor_start_failure_receipt_sha256: None,
            ..failed.clone()
        };
        let error = require_unadopted_stop_cleanup(&raw_failed)
            .expect_err("raw Failed-at-Claimed evidence must not clean up");
        assert!(
            error
                .to_string()
                .contains("lacks exact stopped-run evidence")
        );
        assert!(workspace.exists());
        let settlement = terminal_settlement(&failed, RemoteAssignmentWireState::Failed);
        fixture
            .db
            .settle_task_board_remote_assignment(&settlement, REMOTE_EXECUTOR_PRINCIPAL, SETTLED_AT)
            .await
            .expect("persist immutable failed settlement");
        assert_eq!(active_count(&fixture).await, 1);

        reconcile_remote_executor_assignment(
            &executor_state(&fixture.db, "successor-instance"),
            &fixture.db,
            &failed.assignment_id,
        )
        .await
        .expect("clean the settled Failed-at-Claimed session");

        let cleaned = load_assignment(&fixture, &failed.assignment_id).await;
        assert_eq!(cleaned.state, TaskBoardRemoteAssignmentState::Failed);
        assert!(cleaned.cleanup_completed_at.is_some());
        assert_eq!(active_count(&fixture).await, 0);
        assert!(!workspace.exists());
    })
    .await;
}
