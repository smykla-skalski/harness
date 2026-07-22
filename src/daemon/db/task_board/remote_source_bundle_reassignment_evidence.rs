use sqlx::{Sqlite, Transaction};

use super::remote_assignment_inbox::PREDECESSOR_OFFER_NOT_RECEIVED;
use super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent};
use super::remote_offer_receipts::{
    ensure_rejected_offer_receipt_in_tx, load_offer_receipt_collisions_in_tx,
};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    consume_successor_recovery_operation_trust_in_tx,
};
use super::remote_source_bundle_abandonment::load_abandonment_in_tx;
use super::remote_source_bundles::load_source_bundle_collisions_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[derive(Clone, Copy)]
pub(super) enum SourceReassignmentEvidence<'a> {
    Abandonment {
        request: &'a RemoteSourceBundleAbandonRequest,
        response: &'a RemoteSourceBundleAbandonResponse,
    },
    OfferRejection {
        request: &'a RemoteOfferRequest,
        response: &'a RemoteOfferResponse,
        observed_at: &'a str,
    },
}

impl<'a> SourceReassignmentEvidence<'a> {
    pub(super) fn offer(self) -> &'a RemoteOfferRequest {
        match self {
            Self::Abandonment { request, .. } => &request.offer,
            Self::OfferRejection { request, .. } => request,
        }
    }

    pub(super) fn validate(self) -> Result<(), CliError> {
        match self {
            Self::Abandonment { request, response } => {
                response.validate(request).map_err(|error| {
                    db_error(format!("validate source abandonment evidence: {error}"))
                })
            }
            Self::OfferRejection {
                request, response, ..
            } => {
                response.validate(request).map_err(|error| {
                    db_error(format!("validate predecessor offer rejection: {error}"))
                })?;
                if response.disposition == RemoteOfferDisposition::Rejected
                    && response.rejection_code.as_deref() == Some(PREDECESSOR_OFFER_NOT_RECEIVED)
                {
                    Ok(())
                } else {
                    Err(concurrent(
                        "source reassignment requires authoritative predecessor offer absence",
                    ))
                }
            }
        }
    }
}

pub(super) async fn require_reassignment_evidence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    evidence: SourceReassignmentEvidence<'_>,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    match evidence {
        SourceReassignmentEvidence::Abandonment { request, response } => {
            let abandonment = load_abandonment_in_tx(
                transaction,
                &predecessor.assignment_id,
                predecessor.fencing_epoch,
            )
            .await?
            .ok_or_else(|| concurrent("source reassignment abandonment evidence disappeared"))?;
            if !abandonment.is_exact_replay(request, principal) || abandonment.response != *response
            {
                return Err(concurrent(
                    "source reassignment abandonment evidence changed",
                ));
            }
            if !load_source_bundle_collisions_in_tx(transaction, &request.offer)
                .await?
                .is_empty()
            {
                return Err(concurrent(
                    "source abandonment conflicts with an immutable upload receipt",
                ));
            }
            if predecessor.controller_operation.is_some()
                || !load_offer_receipt_collisions_in_tx(transaction, &request.offer)
                    .await?
                    .is_empty()
            {
                return Err(concurrent(
                    "source abandonment conflicts with pending or durable offer authority",
                ));
            }
        }
        SourceReassignmentEvidence::OfferRejection {
            request,
            response,
            observed_at,
        } => {
            let code = response.rejection_code.as_deref().ok_or_else(|| {
                concurrent("predecessor offer rejection has no durable rejection code")
            })?;
            let receipt = ensure_rejected_offer_receipt_in_tx(
                transaction,
                request,
                principal,
                code,
                observed_at,
            )
            .await?;
            if receipt.response()? != *response {
                return Err(concurrent(
                    "predecessor offer rejection changed from executor evidence",
                ));
            }
            if predecessor.controller_operation.is_some() {
                consume_successor_recovery_operation_trust_in_tx(
                    transaction,
                    predecessor,
                    TaskBoardRemoteOperationKind::Offer,
                    &request.request_sha256,
                    trust,
                )
                .await?;
            } else if predecessor.state != TaskBoardRemoteAssignmentState::Offered
                && predecessor.state != TaskBoardRemoteAssignmentState::Superseded
            {
                return Err(concurrent(
                    "predecessor offer rejection lost its pre-claim generation",
                ));
            }
        }
    }
    Ok(())
}
