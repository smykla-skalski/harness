//! Remote assignment executor/cancel/lease lifecycle query surface for
//! [`AsyncDaemonDb`], consolidated behind one trait so its real bodies --
//! spread across `remote_assignment_executor_scan.rs`,
//! `remote_assignment_executor_stop.rs`, `remote_assignment_executor_terminal.rs`,
//! `remote_assignment_cancel_journal.rs`, `remote_assignment_cancel_response.rs`,
//! `remote_assignment_lease_response.rs` (and its `replay` submodule), and
//! `remote_assignment_terminal_handoff.rs` and `remote_assignment_recovery_queue.rs`
//! -- can each stay in the file they already live in. Rust only allows one
//! `impl Trait for Type` block per type, so this file is the single place
//! `RemoteAssignmentExecutorLifecycleQueries` is implemented; every method
//! body is a one-line forward into the plain function that owns the real
//! logic.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::remote_assignment_cancel_journal;
use super::remote_assignment_cancel_response;
use super::remote_assignment_executor_scan::{self, TaskBoardRemoteExecutorScan};
use super::remote_assignment_executor_stop::{
    self, TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopPending,
    TaskBoardRemoteExecutorStopReason,
};
use super::remote_assignment_executor_terminal::{self, TaskBoardRemoteTerminalArtifact};
use super::remote_assignment_lease_response;
use super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner;
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome};
use super::remote_assignment_recovery_queue::{self, RawRecoveryCandidate};
use super::remote_assignment_terminal_handoff;
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteExecutorRun, TaskBoardRemoteHostTrustFence};
use crate::task_board::TaskBoardWorkflowExecutionCas;
use crate::task_board::remote_wire::wire::{
    RemoteCancelRequest, RemoteCancelResponse, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse,
};

pub(crate) trait RemoteAssignmentExecutorLifecycleQueries: Send + Sync {
    /// Selects bounded, restart-fair executor work and durably advances both cursors.
    async fn scan_task_board_remote_executor_assignments(
        &self,
    ) -> Result<TaskBoardRemoteExecutorScan, CliError>;

    async fn claim_task_board_remote_executor_stop_pending<S>(
        &self,
        authority: &TaskBoardRemoteExecutorStopAuthority,
        snapshot: &S,
        reason: TaskBoardRemoteExecutorStopReason,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStopPending>, CliError>
    where
        S: Clone + Into<TaskBoardRemoteExecutorRun>;

    async fn settle_task_board_remote_executor_stop_pending(
        &self,
        pending: &TaskBoardRemoteExecutorStopPending,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn complete_task_board_remote_executor_terminal(
        &self,
        owner: &TaskBoardRemoteExecutorLifecycleOwner,
        response: &crate::task_board::remote_wire::wire::RemoteStatusResponse,
        artifacts: &[TaskBoardRemoteTerminalArtifact],
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn task_board_remote_cancel_intent(
        &self,
        assignment_id: &str,
    ) -> Result<Option<RemoteCancelRequest>, CliError>;

    async fn record_task_board_remote_assignment_cancel(
        &self,
        request: &RemoteCancelRequest,
        response: &RemoteCancelResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn record_task_board_remote_assignment_lease_renewal(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn record_pending_task_board_remote_assignment_lease_renewal_replay(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn record_task_board_remote_terminal_cleanup_handoff(
        &self,
        expected_assignment: &TaskBoardRemoteAssignmentRecord,
        expected_parent: &TaskBoardWorkflowExecutionCas,
        handed_off_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn task_board_remote_assignment_has_settlement_handoff(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError>;

    async fn quarantine_remote_recovery_failure(
        &self,
        candidate: &RawRecoveryCandidate,
        now: &str,
        error: &CliError,
    ) -> Result<(), CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl RemoteAssignmentExecutorLifecycleQueries for AsyncDaemonDb {
    async fn scan_task_board_remote_executor_assignments(
        &self,
    ) -> Result<TaskBoardRemoteExecutorScan, CliError> {
        remote_assignment_executor_scan::scan_task_board_remote_executor_assignments(self).await
    }

    async fn claim_task_board_remote_executor_stop_pending<S>(
        &self,
        authority: &TaskBoardRemoteExecutorStopAuthority,
        snapshot: &S,
        reason: TaskBoardRemoteExecutorStopReason,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStopPending>, CliError>
    where
        S: Clone + Into<TaskBoardRemoteExecutorRun>,
    {
        remote_assignment_executor_stop::claim_task_board_remote_executor_stop_pending(
            self,
            authority,
            snapshot,
            reason,
            acquired_at,
        )
        .await
    }

    async fn settle_task_board_remote_executor_stop_pending(
        &self,
        pending: &TaskBoardRemoteExecutorStopPending,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_executor_stop::settle_task_board_remote_executor_stop_pending(
            self,
            pending,
            observed_at,
        )
        .await
    }

    async fn complete_task_board_remote_executor_terminal(
        &self,
        owner: &TaskBoardRemoteExecutorLifecycleOwner,
        response: &crate::task_board::remote_wire::wire::RemoteStatusResponse,
        artifacts: &[TaskBoardRemoteTerminalArtifact],
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_executor_terminal::complete_task_board_remote_executor_terminal(
            self, owner, response, artifacts,
        )
        .await
    }

    async fn task_board_remote_cancel_intent(
        &self,
        assignment_id: &str,
    ) -> Result<Option<RemoteCancelRequest>, CliError> {
        remote_assignment_cancel_journal::task_board_remote_cancel_intent(self, assignment_id).await
    }

    async fn record_task_board_remote_assignment_cancel(
        &self,
        request: &RemoteCancelRequest,
        response: &RemoteCancelResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        Box::pin(
            remote_assignment_cancel_response::record_task_board_remote_assignment_cancel(
                self,
                request,
                response,
                authenticated_principal,
                recorded_at,
            ),
        )
        .await
    }

    async fn record_task_board_remote_assignment_lease_renewal(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_lease_response::record_task_board_remote_assignment_lease_renewal(
            self,
            request,
            response,
            authenticated_principal,
            recorded_at,
        )
        .await
    }

    async fn record_pending_task_board_remote_assignment_lease_renewal_replay(
        &self,
        request: &RemoteLeaseRenewRequest,
        response: &RemoteLeaseRenewResponse,
        authenticated_principal: &str,
        recorded_at: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_lease_response::replay::record_pending_task_board_remote_assignment_lease_renewal_replay(
            self,
            request,
            response,
            authenticated_principal,
            recorded_at,
            trust,
        )
        .await
    }

    async fn record_task_board_remote_terminal_cleanup_handoff(
        &self,
        expected_assignment: &TaskBoardRemoteAssignmentRecord,
        expected_parent: &TaskBoardWorkflowExecutionCas,
        handed_off_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_terminal_handoff::record_task_board_remote_terminal_cleanup_handoff(
            self,
            expected_assignment,
            expected_parent,
            handed_off_at,
        )
        .await
    }

    async fn task_board_remote_assignment_has_settlement_handoff(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        remote_assignment_terminal_handoff::task_board_remote_assignment_has_settlement_handoff(
            self,
            assignment_id,
            fencing_epoch,
        )
        .await
    }

    async fn quarantine_remote_recovery_failure(
        &self,
        candidate: &RawRecoveryCandidate,
        now: &str,
        error: &CliError,
    ) -> Result<(), CliError> {
        remote_assignment_recovery_queue::quarantine_remote_recovery_failure(
            self, candidate, now, error,
        )
        .await
    }
}
