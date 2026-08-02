//! Remote assignment authority/trust-fencing query surface for
//! [`AsyncDaemonDb`], consolidated behind one trait so its real bodies --
//! spread across `remote_assignment_io_authority.rs`,
//! `remote_assignment_trusted_authority.rs`, `remote_operation_trust.rs`,
//! `remote_assignment_active_fence.rs`, `remote_assignment_cleanup.rs`,
//! `remote_assignment_cleanup_controller.rs`, and
//! `remote_evidence_retention.rs` -- can each stay in the file they already
//! live in. Rust only allows one `impl Trait for Type` block per type, so
//! this file is the single place `RemoteAssignmentAuthorityQueries` is
//! implemented; every method body is a one-line forward into the plain
//! function that owns the real logic.
//!
//! Distinct from #1170's `RemoteExecutionQueries`, which covers only the 17
//! core lifecycle methods with the highest `service`/`task_board_remote_transport`
//! reference counts; that trait's own rationale explicitly leaves this
//! cluster's methods on the inherent-impl pattern rather than widen its
//! surface, so this is a new trait rather than an addition to it.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

#[cfg(test)]
use super::remote_assignment_active_fence;
use super::remote_assignment_cleanup;
use super::remote_assignment_cleanup_controller;
#[cfg(test)]
use super::remote_assignment_io_authority;
use super::remote_assignment_io_authority::TaskBoardRemoteIoAuthority;
use super::remote_assignment_trusted_authority;
use super::remote_evidence_retention::{self, TaskBoardRemoteEvidencePruneResult};
use super::remote_operation_trust::{
    self, TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
};
use super::remote_assignment_model::TaskBoardRemoteMutationOutcome;
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteHostTrustFence};
use crate::task_board::remote_wire::wire::{
    RemoteCancelRequest, RemoteClaimRequest, RemoteLeaseRenewRequest, RemoteOfferRequest,
    RemoteSettledRequest,
};
use crate::task_board::remote_wire::wire_cleanup::{
    RemoteCleanupObservationRequest, RemoteCleanupObservationResponse,
};

pub(crate) trait RemoteAssignmentAuthorityQueries: Send + Sync {
    #[cfg(test)]
    async fn claim_task_board_remote_offer_io_authority(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    #[cfg(test)]
    async fn claim_task_board_remote_claim_io_authority(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    #[cfg(test)]
    async fn claim_task_board_remote_renew_io_authority(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    #[cfg(test)]
    async fn claim_task_board_remote_cancel_io_authority(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    async fn claim_task_board_remote_offer_io_authority_fenced(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    async fn claim_task_board_remote_claim_io_authority_fenced(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    async fn claim_task_board_remote_renew_io_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    async fn claim_task_board_remote_cancel_io_authority_fenced(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError>;

    async fn require_pending_task_board_remote_renew_replay_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<bool, CliError>;

    async fn task_board_remote_operation_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError>;

    async fn complete_task_board_remote_operation_trust(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
        request_sha256: &str,
    ) -> Result<(), CliError>;

    async fn task_board_remote_lifecycle_operation_trust_fence(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError>;

    #[cfg(test)]
    async fn task_board_execution_has_active_remote_assignment(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError>;

    #[cfg(test)]
    async fn task_board_execution_generation_has_active_remote_assignment(
        &self,
        execution_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError>;

    async fn complete_task_board_remote_assignment_cleanup(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        completed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn task_board_remote_executor_active_assignment_count(
        &self,
        host_id: &str,
    ) -> Result<u32, CliError>;

    async fn claim_task_board_remote_cleanup_observation_fenced(
        &self,
        request: &RemoteCleanupObservationRequest,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<Option<RemoteCleanupObservationResponse>, CliError>;

    async fn record_task_board_remote_cleanup_observation(
        &self,
        request: &RemoteCleanupObservationRequest,
        response: &RemoteCleanupObservationResponse,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn prune_task_board_remote_execution_evidence(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteEvidencePruneResult, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl RemoteAssignmentAuthorityQueries for AsyncDaemonDb {
    #[cfg(test)]
    async fn claim_task_board_remote_offer_io_authority(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_io_authority::claim_task_board_remote_offer_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    #[cfg(test)]
    async fn claim_task_board_remote_claim_io_authority(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_io_authority::claim_task_board_remote_claim_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    #[cfg(test)]
    async fn claim_task_board_remote_renew_io_authority(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_io_authority::claim_task_board_remote_renew_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    #[cfg(test)]
    async fn claim_task_board_remote_cancel_io_authority(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_io_authority::claim_task_board_remote_cancel_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    async fn claim_task_board_remote_offer_io_authority_fenced(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_trusted_authority::claim_task_board_remote_offer_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            authority_at,
            trust,
        )
        .await
    }

    async fn claim_task_board_remote_claim_io_authority_fenced(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_trusted_authority::claim_task_board_remote_claim_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            authority_at,
            trust,
        )
        .await
    }

    async fn claim_task_board_remote_renew_io_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_trusted_authority::claim_task_board_remote_renew_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            authority_at,
            trust,
        )
        .await
    }

    async fn claim_task_board_remote_cancel_io_authority_fenced(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        remote_assignment_trusted_authority::claim_task_board_remote_cancel_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            authority_at,
            trust,
        )
        .await
    }

    async fn require_pending_task_board_remote_renew_replay_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<bool, CliError> {
        remote_assignment_trusted_authority::require_pending_task_board_remote_renew_replay_authority_fenced(
            self,
            request,
            authenticated_principal,
            trust,
        )
        .await
    }

    async fn task_board_remote_operation_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        remote_operation_trust::task_board_remote_operation_trust_fence(self, host_id).await
    }

    async fn complete_task_board_remote_operation_trust(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
        request_sha256: &str,
    ) -> Result<(), CliError> {
        remote_operation_trust::complete_task_board_remote_operation_trust(
            self,
            assignment_id,
            kind,
            request_sha256,
        )
        .await
    }

    async fn task_board_remote_lifecycle_operation_trust_fence(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        remote_operation_trust::task_board_remote_lifecycle_operation_trust_fence(
            self,
            assignment_id,
            kind,
        )
        .await
    }

    #[cfg(test)]
    async fn task_board_execution_has_active_remote_assignment(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        remote_assignment_active_fence::task_board_execution_has_active_remote_assignment(
            self,
            execution_id,
        )
        .await
    }

    #[cfg(test)]
    async fn task_board_execution_generation_has_active_remote_assignment(
        &self,
        execution_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        remote_assignment_active_fence::task_board_execution_generation_has_active_remote_assignment(
            self,
            execution_id,
            fencing_epoch,
        )
        .await
    }

    async fn complete_task_board_remote_assignment_cleanup(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        completed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_cleanup::complete_task_board_remote_assignment_cleanup(
            self,
            request,
            authenticated_principal,
            completed_at,
        )
        .await
    }

    async fn task_board_remote_executor_active_assignment_count(
        &self,
        host_id: &str,
    ) -> Result<u32, CliError> {
        remote_assignment_cleanup::task_board_remote_executor_active_assignment_count(
            self, host_id,
        )
        .await
    }

    async fn claim_task_board_remote_cleanup_observation_fenced(
        &self,
        request: &RemoteCleanupObservationRequest,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<Option<RemoteCleanupObservationResponse>, CliError> {
        remote_assignment_cleanup_controller::claim_task_board_remote_cleanup_observation_fenced(
            self, request, principal, trust,
        )
        .await
    }

    async fn record_task_board_remote_cleanup_observation(
        &self,
        request: &RemoteCleanupObservationRequest,
        response: &RemoteCleanupObservationResponse,
        principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        remote_assignment_cleanup_controller::record_task_board_remote_cleanup_observation(
            self, request, response, principal, trust,
        )
        .await
    }

    async fn prune_task_board_remote_execution_evidence(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteEvidencePruneResult, CliError> {
        remote_evidence_retention::prune_task_board_remote_execution_evidence(self, now).await
    }
}
