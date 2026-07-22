use super::remote_assignment_executor_terminal_test_support::completed_evidence;
use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorLifecycleOwner,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopPending,
    TaskBoardRemoteExecutorStopReason, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCancelRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

mod lifecycle;
mod pre_permit;
mod start;

async fn claim_executor(fixture: &ExecutorFixture) -> TaskBoardRemoteAssignmentRecord {
    let accepted = accept_executor(fixture, &fixture.request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &claim_request(&fixture.request, &accepted),
                PRINCIPAL,
                CLAIMED_AT,
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    accepted
}
