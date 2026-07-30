//! The remote-execution cluster's own interface onto [`AsyncDaemonDb`],
//! scoped to the assignment offer/claim/lease/settle lifecycle, executor
//! start authority, host trust, and controller scan operations that
//! `service` and `task_board_remote_transport` reach into most.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for these queries can never move
//! into a crate `task_board` doesn't share with `db`. A trait `task_board`
//! itself declares has no such problem: Rust's orphan rule only requires one
//! of the trait or the implementing type to be local, and the trait is. That
//! is what lets this cluster move into its own crate later without dragging
//! every other area's inherent impls along for the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside
//! `db/task_board` has to change to keep calling them by the same name.
//!
//! This covers the cluster's two heavily-shared types
//! ([`TaskBoardRemoteAssignmentRecord`] and [`TaskBoardRemoteMutationOutcome`],
//! reached through nearly every method below) and the seventeen lifecycle
//! operations that account for the bulk of real caller traffic,
//! verified by reference count against `service` and
//! `task_board_remote_transport`. The cluster's much longer tail of
//! narrowly-used internal accessors -- io-authority-fencing variants, source
//! bundle plumbing, receipt decoders, and other single-digit-reference
//! helpers -- stays on the inherent-impl pattern for now; forcing each one
//! through this trait would relocate detail without reducing it. See the
//! introducing PR for the full accounting.

use std::path::Path;

use super::remote_assignment_controller_scan::TaskBoardRemoteControllerScanStep;
use super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome,
};
use super::remote_assignment_offer::TaskBoardRemoteOfferWindow;
use super::remote_assignment_recovery::TaskBoardRemoteRecoveryBatch;
use super::remote_assignment_start_authority::{
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStartIoPermitOutcome,
};
use super::remote_hosts::TaskBoardRemoteHostTrustFence;
use super::remote_result_import::TaskBoardRemoteResultImportRecord;
use super::remote_settlement_receipts::TaskBoardRemoteSettlementReceipt;
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::remote_wire::wire::{
    RemoteClaimRequest, RemoteClaimResponse, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSettledRequest, RemoteStatusRequest, RemoteStatusResponse,
};
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

pub(crate) trait RemoteExecutionQueries: Send + Sync {
    async fn task_board_remote_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError>;

    async fn claim_task_board_remote_assignment(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        claimed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn claim_task_board_remote_executor_start_io_permit(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        project_dir: &Path,
        permitted_at: &str,
    ) -> Result<TaskBoardRemoteExecutorStartIoPermitOutcome, CliError>;

    async fn task_board_remote_settlement_receipt(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteSettlementReceipt>, CliError>;

    async fn settle_task_board_remote_assignment(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        settled_at: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError>;

    async fn task_board_remote_host_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteHostTrustFence, CliError>;

    async fn offer_task_board_remote_assignment(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        window: TaskBoardRemoteOfferWindow<'_>,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError>;

    async fn record_task_board_remote_assignment_status(
        &self,
        request: &RemoteStatusRequest,
        response: &RemoteStatusResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn claim_task_board_remote_executor_start_authority(
        &self,
        assignment_id: &str,
        host_instance_id: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError>;

    /// Claims one restart-replayable controller generation for remote verification.
    async fn next_task_board_remote_controller_assignment(
        &self,
        now: &str,
    ) -> Result<Option<TaskBoardRemoteControllerScanStep>, CliError>;

    async fn record_task_board_remote_offer_response(
        &self,
        response: &RemoteOfferResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn task_board_remote_result_import(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<Option<TaskBoardRemoteResultImportRecord>, CliError>;

    async fn exact_task_board_remote_claim_receipt(
        &self,
        request: &RemoteClaimRequest,
        principal: &str,
    ) -> Result<Option<(RemoteClaimResponse, TaskBoardRemoteAssignmentRecord)>, CliError>;

    async fn recover_task_board_remote_assignments(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteRecoveryBatch, CliError>;

    async fn accept_task_board_remote_assignment_offer(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        accepted_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError>;

    async fn claim_task_board_remote_executor_lifecycle_owner(
        &self,
        assignment_id: &str,
        owner_instance_id: &str,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorLifecycleOwner>, CliError>;

    async fn record_task_board_remote_assignment_claim(
        &self,
        request: &RemoteClaimRequest,
        response: &RemoteClaimResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// operation's logic, kept in the file the query has always lived in
/// (`remote_assignment_lease.rs`, `remote_hosts.rs`, and so on) so this file
/// stays a pure interface plus wiring, not a seventeen-method dumping ground.
impl RemoteExecutionQueries for AsyncDaemonDb {
    async fn task_board_remote_assignment(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
        super::remote_assignment_model::task_board_remote_assignment(self, assignment_id).await
    }

    async fn claim_task_board_remote_assignment(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        claimed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        super::remote_assignment_lease::claim_task_board_remote_assignment(
            self,
            request,
            authenticated_principal,
            claimed_at,
        )
        .await
    }

    async fn claim_task_board_remote_executor_start_io_permit(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        project_dir: &Path,
        permitted_at: &str,
    ) -> Result<TaskBoardRemoteExecutorStartIoPermitOutcome, CliError> {
        super::remote_assignment_start_authority::claim_task_board_remote_executor_start_io_permit(
            self,
            authority,
            project_dir,
            permitted_at,
        )
        .await
    }

    async fn task_board_remote_settlement_receipt(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteSettlementReceipt>, CliError> {
        super::remote_settlement_receipts::task_board_remote_settlement_receipt(self, assignment_id)
            .await
    }

    async fn settle_task_board_remote_assignment(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        settled_at: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
        super::remote_settlement_receipts::settle_task_board_remote_assignment(
            self,
            request,
            authenticated_principal,
            settled_at,
        )
        .await
    }

    async fn task_board_remote_host_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
        super::remote_hosts::task_board_remote_host_trust_fence(self, host_id).await
    }

    async fn offer_task_board_remote_assignment(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        window: TaskBoardRemoteOfferWindow<'_>,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        super::remote_assignment_offer::offer_task_board_remote_assignment(
            self,
            expected_execution,
            expected_attempt,
            request,
            authenticated_principal,
            window,
        )
        .await
    }

    async fn record_task_board_remote_assignment_status(
        &self,
        request: &RemoteStatusRequest,
        response: &RemoteStatusResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        Box::pin(
            super::remote_assignment_status::record_task_board_remote_assignment_status(
                self,
                request,
                response,
                authenticated_principal,
            ),
        )
        .await
    }

    async fn claim_task_board_remote_executor_start_authority(
        &self,
        assignment_id: &str,
        host_instance_id: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
        super::remote_assignment_start_authority::claim_task_board_remote_executor_start_authority(
            self,
            assignment_id,
            host_instance_id,
            authority_at,
        )
        .await
    }

    async fn next_task_board_remote_controller_assignment(
        &self,
        now: &str,
    ) -> Result<Option<TaskBoardRemoteControllerScanStep>, CliError> {
        super::remote_assignment_controller_scan::next_task_board_remote_controller_assignment(
            self, now,
        )
        .await
    }

    async fn record_task_board_remote_offer_response(
        &self,
        response: &RemoteOfferResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        Box::pin(
            super::remote_assignment_terminal::record_task_board_remote_offer_response(
                self,
                response,
                authenticated_principal,
                observed_at,
            ),
        )
        .await
    }

    async fn task_board_remote_result_import(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<Option<TaskBoardRemoteResultImportRecord>, CliError> {
        super::remote_result_import::task_board_remote_result_import(
            self,
            assignment_id,
            fencing_epoch,
        )
        .await
    }

    async fn exact_task_board_remote_claim_receipt(
        &self,
        request: &RemoteClaimRequest,
        principal: &str,
    ) -> Result<Option<(RemoteClaimResponse, TaskBoardRemoteAssignmentRecord)>, CliError> {
        super::remote_claim_receipts::exact_task_board_remote_claim_receipt(
            self, request, principal,
        )
        .await
    }

    async fn recover_task_board_remote_assignments(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteRecoveryBatch, CliError> {
        super::remote_assignment_recovery::recover_task_board_remote_assignments(self, now).await
    }

    async fn accept_task_board_remote_assignment_offer(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        accepted_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        super::remote_assignment_inbox::accept_task_board_remote_assignment_offer(
            self,
            request,
            authenticated_principal,
            host_instance_id,
            accepted_at,
        )
        .await
    }

    async fn claim_task_board_remote_executor_lifecycle_owner(
        &self,
        assignment_id: &str,
        owner_instance_id: &str,
        acquired_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorLifecycleOwner>, CliError> {
        super::remote_assignment_lifecycle_owner::claim_task_board_remote_executor_lifecycle_owner(
            self,
            assignment_id,
            owner_instance_id,
            acquired_at,
        )
        .await
    }

    async fn record_task_board_remote_assignment_claim(
        &self,
        request: &RemoteClaimRequest,
        response: &RemoteClaimResponse,
        authenticated_principal: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        Box::pin(
            super::remote_assignment_claim_response::record_task_board_remote_assignment_claim(
                self,
                request,
                response,
                authenticated_principal,
                observed_at,
            ),
        )
        .await
    }
}
