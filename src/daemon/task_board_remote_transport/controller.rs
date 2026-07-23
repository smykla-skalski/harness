use std::error::Error;
use std::fmt;

use super::client::{RemoteExecutionHttpClient, RemoteExecutionHttpError};
use super::controller_cancel_replay::durable_cancel_response;
use super::controller_clock::ControllerClock;
use super::wire::{
    RemoteArtifactFetchRequest, RemoteCancelRequest, RemoteCancelResponse, RemoteClaimRequest,
    RemoteClaimResponse, RemoteLeaseRenewRequest, RemoteLeaseRenewResponse, RemoteOfferRequest,
    RemoteOfferResponse, RemoteSettledRequest, RemoteSettledResponse, RemoteStatusRequest,
    RemoteStatusResponse,
};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteArtifact, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteHostTrustFence, TaskBoardRemoteMutationOutcome, TaskBoardRemoteOperationKind,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::TaskBoardRemoteAssignmentState;

/// Authenticated, pinned controller-side connection to one configured executor.
///
/// The operator-owned host id is also the paired `ExecutionCoordinator`
/// client id. The referenced credential must resolve to that exact identity's
/// token on the executor; no generic Operator credential is accepted.
#[derive(Debug)]
pub(crate) struct RemoteExecutionControllerClient {
    pub(super) host_id: String,
    pub(super) client: RemoteExecutionHttpClient,
    pub(super) clock: ControllerClock,
    pub(super) retained_trust: Option<TaskBoardRemoteHostTrustFence>,
}

#[derive(Debug)]
pub(crate) enum RemoteExecutionControllerError {
    Transport(RemoteExecutionHttpError),
    Database(CliError),
}

impl fmt::Display for RemoteExecutionControllerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(error) => write!(formatter, "{error}"),
            Self::Database(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for RemoteExecutionControllerError {}

impl From<RemoteExecutionHttpError> for RemoteExecutionControllerError {
    fn from(error: RemoteExecutionHttpError) -> Self {
        Self::Transport(error)
    }
}

impl From<CliError> for RemoteExecutionControllerError {
    fn from(error: CliError) -> Self {
        Self::Database(error)
    }
}

impl RemoteExecutionControllerClient {
    pub(crate) async fn offer(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteOfferRequest,
    ) -> Result<(RemoteOfferResponse, TaskBoardRemoteMutationOutcome), RemoteExecutionControllerError>
    {
        if let Some(receipt) = db
            .exact_task_board_remote_offer_receipt(request, &self.host_id)
            .await?
        {
            let record = self.preflight(db, &request.binding.assignment_id).await?;
            return Ok((
                receipt.response()?,
                TaskBoardRemoteMutationOutcome::Replayed(record),
            ));
        }
        let record = self.preflight(db, &request.binding.assignment_id).await?;
        verify_offer_preflight(&record, request, &self.host_id)?;
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Offer,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_offer_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote offer lost workflow I/O authority",
        )?;
        let response = self.client.offer(request).await?;
        let settled_at = self.clock.now();
        let outcome = Box::pin(db.record_task_board_remote_offer_response(
            &response,
            &self.host_id,
            &settled_at,
        ))
        .await?;
        Ok((response, outcome))
    }

    pub(crate) async fn claim(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteClaimRequest,
    ) -> Result<(RemoteClaimResponse, TaskBoardRemoteMutationOutcome), RemoteExecutionControllerError>
    {
        if let Some((response, record)) = db
            .exact_task_board_remote_claim_receipt(request, &self.host_id)
            .await?
        {
            return Ok((response, TaskBoardRemoteMutationOutcome::Replayed(record)));
        }
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        if record.state != TaskBoardRemoteAssignmentState::Offered {
            return Err(binding_error("remote claim is no longer active").into());
        }
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Claim,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_claim_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote claim lost workflow I/O authority",
        )?;
        let response = self.client.claim(request).await?;
        let settled_at = self.clock.now();
        let outcome = Box::pin(db.record_task_board_remote_assignment_claim(
            request,
            &response,
            &self.host_id,
            &settled_at,
        ))
        .await?;
        Ok((response, outcome))
    }

    pub(crate) async fn renew_lease(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteLeaseRenewRequest,
    ) -> Result<
        (RemoteLeaseRenewResponse, TaskBoardRemoteMutationOutcome),
        RemoteExecutionControllerError,
    > {
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        if !matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
        ) {
            return Err(binding_error("remote lease renewal is no longer active").into());
        }
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Renew,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_renew_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote lease renewal lost workflow I/O authority",
        )?;
        let response = match self.client.renew_lease(request).await {
            Ok(response) => response,
            Err(error) if renewal_response_may_be_lost(&error) => {
                self.client.renew_lease(request).await?
            }
            Err(error) => return Err(error.into()),
        };
        let settled_at = self.clock.now();
        let outcome = Box::pin(db.record_task_board_remote_assignment_lease_renewal(
            request,
            &response,
            &self.host_id,
            &settled_at,
        ))
        .await?;
        Ok((response, outcome))
    }

    pub(crate) async fn status(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteStatusRequest,
    ) -> Result<
        (RemoteStatusResponse, TaskBoardRemoteMutationOutcome),
        RemoteExecutionControllerError,
    > {
        self.preflight_lifecycle(
            db,
            request.binding.assignment_id.as_str(),
            request.lease_id.as_str(),
            request.offer_request_sha256.as_str(),
            &request.binding,
        )
        .await?;
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Status,
                &request.binding.assignment_id,
            )
            .await?;
        if !Box::pin(db.claim_task_board_remote_status_io_authority_fenced(
            request,
            &self.host_id,
            &trust,
        ))
        .await?
        {
            return Err(binding_error("remote status lost its assignment authority").into());
        }
        let response = self.client.status(request).await?;
        let outcome = Box::pin(db.record_task_board_remote_assignment_status(
            request,
            &response,
            &self.host_id,
        ))
        .await?;
        Ok((response, outcome))
    }

    pub(crate) async fn cancel(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteCancelRequest,
    ) -> Result<
        (RemoteCancelResponse, TaskBoardRemoteMutationOutcome),
        RemoteExecutionControllerError,
    > {
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        if let Some(response) = durable_cancel_response(&record, request)? {
            return Ok((response, TaskBoardRemoteMutationOutcome::Replayed(record)));
        }
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Cancel,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        require_io_authority(
            db.claim_task_board_remote_cancel_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?,
            "remote cancellation lost workflow I/O authority",
        )?;
        let response = match self.client.cancel(request).await {
            Ok(response) => response,
            Err(error) if lifecycle_response_may_be_lost(&error) => {
                self.client.cancel(request).await?
            }
            Err(error) => return Err(error.into()),
        };
        let settled_at = self.clock.now();
        let outcome = Box::pin(db.record_task_board_remote_assignment_cancel(
            request,
            &response,
            &self.host_id,
            &settled_at,
        ))
        .await?;
        Ok((response, outcome))
    }

    pub(crate) async fn settle(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteSettledRequest,
    ) -> Result<RemoteSettledResponse, RemoteExecutionControllerError> {
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::Settle,
                &request.binding.assignment_id,
            )
            .await?;
        let authority_at = self.clock.now();
        if let Some(response) = db
            .claim_task_board_remote_settlement_io_authority_fenced(
                request,
                &self.host_id,
                &authority_at,
                &trust,
            )
            .await?
        {
            return Ok(response);
        }
        let response = match self.client.settle(request).await {
            Ok(response) => response,
            Err(error) if lifecycle_response_may_be_lost(&error) => {
                self.client.settle(request).await?
            }
            Err(error) => return Err(error.into()),
        };
        db.record_task_board_remote_settlement_response(request, &response, &self.host_id)
            .await?;
        Ok(response)
    }

    pub(crate) async fn fetch_artifact(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteArtifactFetchRequest,
    ) -> Result<TaskBoardRemoteArtifact, RemoteExecutionControllerError> {
        if let Some(stored) = db
            .task_board_remote_artifact(request, &self.host_id)
            .await?
        {
            return Ok(stored);
        }
        let record = self
            .preflight_lifecycle(
                db,
                request.binding.assignment_id.as_str(),
                request.lease_id.as_str(),
                request.offer_request_sha256.as_str(),
                &request.binding,
            )
            .await?;
        verify_artifact_preflight(&record, request)?;
        let trust = self
            .current_operation_trust_for(
                db,
                TaskBoardRemoteOperationKind::FetchArtifact,
                &request.binding.assignment_id,
            )
            .await?;
        if !db
            .claim_task_board_remote_artifact_fetch_io_authority_fenced(
                request,
                &self.host_id,
                &trust,
            )
            .await?
        {
            return Err(binding_error("remote artifact lost its assignment authority").into());
        }
        let response = self.client.fetch_artifact(request).await?;
        let stored_at = self.clock.now();
        db.record_task_board_remote_artifact_fetch_response(
            request,
            &response,
            &self.host_id,
            &stored_at,
        )
        .await
        .map_err(Into::into)
    }

    pub(super) async fn preflight(
        &self,
        db: &AsyncDaemonDb,
        assignment_id: &str,
    ) -> Result<TaskBoardRemoteAssignmentRecord, RemoteExecutionControllerError> {
        db.task_board_remote_assignment(assignment_id)
            .await?
            .ok_or_else(|| binding_error("remote assignment does not exist").into())
    }

    pub(super) async fn preflight_lifecycle(
        &self,
        db: &AsyncDaemonDb,
        assignment_id: &str,
        lease_id: &str,
        offer_digest: &str,
        binding: &super::wire::RemoteAttemptBinding,
    ) -> Result<TaskBoardRemoteAssignmentRecord, RemoteExecutionControllerError> {
        let record = self.preflight(db, assignment_id).await?;
        let offer = record.require_offer()?;
        let exact = binding.host_id == self.host_id
            && offer.binding == *binding
            && offer.request_sha256 == offer_digest
            && record.authenticated_principal.as_deref() == Some(self.host_id.as_str())
            && record.lease_id.as_deref() == Some(lease_id);
        if exact {
            Ok(record)
        } else {
            Err(binding_error("remote operation failed its durable preflight").into())
        }
    }
}

fn require_io_authority(
    authority: Option<crate::daemon::db::TaskBoardRemoteIoAuthority>,
    message: &'static str,
) -> Result<(), RemoteExecutionControllerError> {
    authority
        .map(|_| ())
        .ok_or_else(|| binding_error(message).into())
}

fn verify_offer_preflight(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteOfferRequest,
    host_id: &str,
) -> Result<(), RemoteExecutionControllerError> {
    let exact = record.state == TaskBoardRemoteAssignmentState::Offered
        && record.offer.as_ref() == Some(request)
        && record.authenticated_principal.as_deref() == Some(host_id)
        && record.lease_id.is_none()
        && request.binding.host_id == host_id;
    if exact {
        Ok(())
    } else {
        Err(binding_error("remote offer was not durably persisted before I/O").into())
    }
}

fn verify_artifact_preflight(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteArtifactFetchRequest,
) -> Result<(), RemoteExecutionControllerError> {
    let exact = record.status_response.as_ref().is_some_and(|status| {
        status.output_artifacts.entries.iter().any(|entry| {
            entry.relative_path == request.relative_path && entry.sha256 == request.expected_sha256
        })
    });
    if exact {
        Ok(())
    } else {
        Err(binding_error("remote artifact failed its durable manifest preflight").into())
    }
}

pub(super) fn binding_error(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

pub(super) fn renewal_response_may_be_lost(error: &RemoteExecutionHttpError) -> bool {
    lifecycle_response_may_be_lost(error)
}

pub(super) fn lifecycle_response_may_be_lost(error: &RemoteExecutionHttpError) -> bool {
    matches!(
        error,
        RemoteExecutionHttpError::Transport
            | RemoteExecutionHttpError::ResponseTooLarge
            | RemoteExecutionHttpError::Decode
            | RemoteExecutionHttpError::Wire(_)
    ) || matches!(
        error,
        // `status` is borrowed by the match, so `contains` receives `&u16` directly.
        RemoteExecutionHttpError::HttpStatus { status, .. } if (500..=599).contains(status)
    )
}
