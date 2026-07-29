use super::TaskBoardRemoteIoAuthorityKind;
use crate::daemon::db::task_board::remote_operation_trust::TaskBoardRemoteOperationTrustFence;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAttemptBinding, RemoteCancelRequest, RemoteClaimRequest, RemoteLeaseRenewRequest,
    RemoteOfferRequest,
};

#[derive(Debug, Clone, Copy)]
pub(in crate::daemon::db::task_board) enum RemoteIoAuthorityRequestEvidence<'a> {
    Offer(&'a RemoteOfferRequest),
    Claim(&'a RemoteClaimRequest),
    Renew(&'a RemoteLeaseRenewRequest),
    Cancel(&'a RemoteCancelRequest),
}

pub(in crate::daemon::db::task_board) struct RemoteIoAuthorityClaim<'a> {
    pub(in crate::daemon::db::task_board) request: RemoteIoAuthorityRequestEvidence<'a>,
    pub(in crate::daemon::db::task_board) principal: &'a str,
    pub(in crate::daemon::db::task_board) authority_at: &'a str,
    pub(in crate::daemon::db::task_board) expected_trust:
        Option<&'a TaskBoardRemoteOperationTrustFence>,
}

impl<'a> RemoteIoAuthorityRequestEvidence<'a> {
    pub(super) fn binding(self) -> &'a RemoteAttemptBinding {
        match self {
            Self::Offer(request) => &request.binding,
            Self::Claim(request) => &request.binding,
            Self::Renew(request) => &request.binding,
            Self::Cancel(request) => &request.binding,
        }
    }

    pub(super) fn operation_digest(self) -> &'a str {
        match self {
            Self::Offer(request) => &request.request_sha256,
            Self::Claim(request) => &request.request_sha256,
            Self::Renew(request) => &request.request_sha256,
            Self::Cancel(request) => &request.request_sha256,
        }
    }

    pub(super) fn offer_digest(self) -> &'a str {
        match self {
            Self::Offer(request) => &request.request_sha256,
            Self::Claim(request) => &request.offer_request_sha256,
            Self::Renew(request) => &request.offer_request_sha256,
            Self::Cancel(request) => &request.offer_request_sha256,
        }
    }

    pub(super) fn lease_id(self) -> Option<&'a str> {
        match self {
            Self::Offer(_) => None,
            Self::Claim(request) => Some(&request.lease_id),
            Self::Renew(request) => Some(&request.lease_id),
            Self::Cancel(request) => Some(&request.lease_id),
        }
    }

    pub(super) const fn kind(self) -> TaskBoardRemoteIoAuthorityKind {
        match self {
            Self::Offer(_) => TaskBoardRemoteIoAuthorityKind::Offer,
            Self::Claim(_) => TaskBoardRemoteIoAuthorityKind::Claim,
            Self::Renew(_) => TaskBoardRemoteIoAuthorityKind::Renew,
            Self::Cancel(_) => TaskBoardRemoteIoAuthorityKind::Cancel,
        }
    }

    pub(super) const fn renew_request(self) -> Option<&'a RemoteLeaseRenewRequest> {
        match self {
            Self::Renew(request) => Some(request),
            Self::Offer(_) | Self::Claim(_) | Self::Cancel(_) => None,
        }
    }

    pub(super) const fn cancel_request(self) -> Option<&'a RemoteCancelRequest> {
        match self {
            Self::Cancel(request) => Some(request),
            Self::Offer(_) | Self::Claim(_) | Self::Renew(_) => None,
        }
    }
}
