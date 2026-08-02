//! `#[cfg(test)]`-only convenience wrappers around [`super::claim_remote_io_authority`]
//! with no expected trust fence, split out of `remote_assignment_io_authority.rs` to
//! keep that file under the repo's line cap.

use super::super::remote_assignment_authority_queries::RemoteAssignmentAuthorityQueries;
use super::{RemoteIoAuthorityClaim, RemoteIoAuthorityRequestEvidence, TaskBoardRemoteIoAuthority};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::remote_wire::wire::{
    RemoteCancelRequest, RemoteClaimRequest, RemoteLeaseRenewRequest, RemoteOfferRequest,
};

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_offer_io_authority(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::claim_task_board_remote_offer_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_claim_io_authority(
        &self,
        request: &RemoteClaimRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::claim_task_board_remote_claim_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_renew_io_authority(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::claim_task_board_remote_renew_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    pub(crate) async fn claim_task_board_remote_cancel_io_authority(
        &self,
        request: &RemoteCancelRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::claim_task_board_remote_cancel_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }
}

pub(in super::super) async fn claim_task_board_remote_offer_io_authority(
    db: &AsyncDaemonDb,
    request: &RemoteOfferRequest,
    authenticated_principal: &str,
    authority_at: &str,
) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote offer I/O authority: {error}")))?;
    let claim = RemoteIoAuthorityClaim {
        request: RemoteIoAuthorityRequestEvidence::Offer(request),
        principal: authenticated_principal,
        authority_at,
        expected_trust: None,
    };
    super::claim_remote_io_authority(db, &claim).await
}

pub(in super::super) async fn claim_task_board_remote_claim_io_authority(
    db: &AsyncDaemonDb,
    request: &RemoteClaimRequest,
    authenticated_principal: &str,
    authority_at: &str,
) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote claim I/O authority: {error}")))?;
    let claim = RemoteIoAuthorityClaim {
        request: RemoteIoAuthorityRequestEvidence::Claim(request),
        principal: authenticated_principal,
        authority_at,
        expected_trust: None,
    };
    super::claim_remote_io_authority(db, &claim).await
}

pub(in super::super) async fn claim_task_board_remote_renew_io_authority(
    db: &AsyncDaemonDb,
    request: &RemoteLeaseRenewRequest,
    authenticated_principal: &str,
    authority_at: &str,
) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote renewal I/O authority: {error}")))?;
    let claim = RemoteIoAuthorityClaim {
        request: RemoteIoAuthorityRequestEvidence::Renew(request),
        principal: authenticated_principal,
        authority_at,
        expected_trust: None,
    };
    super::claim_remote_io_authority(db, &claim).await
}

pub(in super::super) async fn claim_task_board_remote_cancel_io_authority(
    db: &AsyncDaemonDb,
    request: &RemoteCancelRequest,
    authenticated_principal: &str,
    authority_at: &str,
) -> Result<Option<TaskBoardRemoteIoAuthority>, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote cancel I/O authority: {error}")))?;
    let claim = RemoteIoAuthorityClaim {
        request: RemoteIoAuthorityRequestEvidence::Cancel(request),
        principal: authenticated_principal,
        authority_at,
        expected_trust: None,
    };
    super::claim_remote_io_authority(db, &claim).await
}
