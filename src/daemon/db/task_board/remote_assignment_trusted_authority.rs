use super::TaskBoardRemoteIoAuthority;
use super::remote_assignment_io_authority::{
    TaskBoardRemoteIoAuthorityKind, require_authority_parent,
};
use super::remote_assignment_lease::{commit_noop, renew_request_for_record};
use super::remote_assignment_model::{concurrent, load_assignment_in_tx};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    require_pending_operation_replay_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteHostTrustFence};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteCancelRequest, RemoteClaimRequest, RemoteLeaseRenewRequest, RemoteOfferRequest,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_offer_io_authority_fenced(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request.validate().map_err(|error| {
            crate::daemon::db::db_error(format!("validate remote offer I/O authority: {error}"))
        })?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.request_sha256,
            None,
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Offer,
            authority_at,
            None,
            None,
            Some(trust),
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_claim_io_authority_fenced(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request.validate().map_err(|error| {
            crate::daemon::db::db_error(format!("validate remote claim I/O authority: {error}"))
        })?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Claim,
            authority_at,
            None,
            None,
            Some(trust),
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_renew_io_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request.validate().map_err(|error| {
            crate::daemon::db::db_error(format!("validate remote renewal I/O authority: {error}"))
        })?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Renew,
            authority_at,
            Some(request),
            None,
            Some(trust),
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_cancel_io_authority_fenced(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        request.validate().map_err(|error| {
            crate::daemon::db::db_error(format!("validate remote cancel I/O authority: {error}"))
        })?;
        self.claim_remote_io_authority(
            &request.binding,
            &request.request_sha256,
            &request.offer_request_sha256,
            Some(&request.lease_id),
            authenticated_principal,
            TaskBoardRemoteIoAuthorityKind::Cancel,
            authority_at,
            None,
            Some(request),
            Some(trust),
        )
        .await
    }

    pub(crate) async fn require_pending_task_board_remote_renew_replay_authority_fenced(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<bool, CliError> {
        request.validate().map_err(|error| {
            crate::daemon::db::db_error(format!("validate pending remote renewal replay: {error}"))
        })?;
        let mut transaction = self
            .begin_immediate_transaction("pending remote renewal replay authority")
            .await?;
        let Some(assignment) =
            load_assignment_in_tx(&mut transaction, &request.binding.assignment_id).await?
        else {
            commit_noop(transaction, "missing pending renewal replay assignment").await?;
            return Ok(false);
        };
        let exact = matches!(
            assignment.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ) && assignment.offer.as_ref().map(|offer| &offer.binding)
            == Some(&request.binding)
            && assignment.request_sha256.as_deref() == Some(request.offer_request_sha256.as_str())
            && assignment.authenticated_principal.as_deref() == Some(authenticated_principal)
            && assignment.lease_id.as_deref() == Some(request.lease_id.as_str())
            && renew_request_for_record(&assignment)? == *request;
        if !exact {
            return Err(concurrent(
                "pending remote renewal replay changed its assignment evidence",
            ));
        }
        require_pending_operation_replay_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::Renew,
            &request.request_sha256,
            trust,
        )
        .await?;
        require_authority_parent(
            &mut transaction,
            &assignment,
            TaskBoardRemoteIoAuthorityKind::Renew,
            &request.request_sha256,
        )
        .await?;
        commit_noop(transaction, "pending remote renewal replay authority").await?;
        Ok(true)
    }
}
