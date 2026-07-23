use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lease::require_assignment;
#[cfg(test)]
use super::remote_assignment_model::insert_assignment_in_tx;
use super::remote_assignment_model::{concurrent, nonblank};
#[cfg(test)]
use super::remote_lifecycle_trust::capture_lifecycle_trust_for_offer_in_tx;
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx, consume_controller_operation_trust_in_tx,
};
use super::remote_source_bundles::{
    TaskBoardRemoteSourceBundle, insert_source_bundle_in_tx, load_source_bundle_collisions_in_tx,
    load_source_bundle_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

impl AsyncDaemonDb {
    pub(crate) async fn exact_task_board_remote_source_bundle_upload_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate source upload replay: {error}")))?;
        nonblank(authenticated_principal, "source upload replay principal")?;
        let mut transaction =
            self.pool().begin().await.map_err(|error| {
                db_error(format!("begin source upload receipt replay: {error}"))
            })?;
        let collisions =
            load_source_bundle_collisions_in_tx(&mut transaction, &request.offer).await?;
        let result = exact_receipt(&collisions, request, authenticated_principal)?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit source upload receipt replay: {error}")))?;
        Ok(result)
    }

    pub(crate) async fn claim_task_board_remote_source_bundle_upload_io_authority_fenced(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate source upload authority: {error}")))?;
        nonblank(authenticated_principal, "source upload authority principal")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote source upload authority")
            .await?;
        let collisions =
            load_source_bundle_collisions_in_tx(&mut transaction, &request.offer).await?;
        if exact_receipt(&collisions, request, authenticated_principal)?.is_some() {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed source upload authority: {error}"))
            })?;
            return Ok(false);
        }
        if super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx(
            &mut transaction,
            &request.offer,
        )
        .await?
        {
            return Err(concurrent(
                "source upload authority belongs to an abandoned generation",
            ));
        }
        let assignment =
            require_assignment(&mut transaction, &request.offer.binding.assignment_id).await?;
        require_upload_assignment(&assignment, request, authenticated_principal)?;
        claim_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.request_sha256,
            Some(trust),
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit source upload authority: {error}")))?;
        Ok(true)
    }

    pub(crate) async fn record_task_board_remote_source_bundle_upload_response(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        response: &RemoteSourceBundleUploadResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError> {
        response
            .validate(request)
            .map_err(|error| db_error(format!("validate source upload response: {error}")))?;
        nonblank(authenticated_principal, "source upload response principal")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote source upload response")
            .await?;
        let collisions =
            load_source_bundle_collisions_in_tx(&mut transaction, &request.offer).await?;
        if let Some(existing) = exact_receipt(&collisions, request, authenticated_principal)? {
            if existing.response != *response {
                return Err(concurrent(
                    "source upload response changed after immutable receipt storage",
                ));
            }
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed source upload response: {error}"))
            })?;
            return Ok(existing);
        }
        if super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx(
            &mut transaction,
            &request.offer,
        )
        .await?
        {
            return Err(concurrent(
                "source upload response belongs to an abandoned generation",
            ));
        }
        let assignment =
            require_assignment(&mut transaction, &request.offer.binding.assignment_id).await?;
        require_upload_assignment(&assignment, request, authenticated_principal)?;
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::UploadSourceBundle,
            &request.request_sha256,
        )
        .await?;
        insert_source_bundle_in_tx(&mut transaction, request, authenticated_principal, response)
            .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let stored = load_source_bundle_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            request.offer.binding.fencing_epoch,
        )
        .await?
        .ok_or_else(|| db_error("persisted controller source upload receipt disappeared"))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit source upload response: {error}")))?;
        Ok(stored)
    }
}

#[cfg(test)]
impl AsyncDaemonDb {
    pub(crate) async fn insert_task_board_remote_source_bundle_offer_for_test(
        &self,
        request: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
        principal: &str,
        offered_at: &str,
        lease_expires_at: &str,
        deadline_at: &str,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("test controller source offer")
            .await?;
        let lifecycle_trust =
            capture_lifecycle_trust_for_offer_in_tx(&mut transaction, request).await?;
        insert_assignment_in_tx(
            &mut transaction,
            request,
            principal,
            offered_at,
            None,
            lease_expires_at,
            deadline_at,
            None,
            None,
            Some(&lifecycle_trust),
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit test controller source offer: {error}")))
    }
}

fn exact_receipt(
    collisions: &[TaskBoardRemoteSourceBundle],
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
    match collisions {
        [] => Ok(None),
        [stored] if stored.is_exact_replay(request, principal) => Ok(Some(stored.clone())),
        _ => Err(concurrent(
            "source upload identity, generation, principal, or digest conflicts",
        )),
    }
}

pub(super) fn require_upload_assignment(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<(), CliError> {
    let exact = assignment.state == TaskBoardRemoteAssignmentState::Offered
        && assignment.offer.as_ref() == Some(&request.offer)
        && assignment.authenticated_principal.as_deref() == Some(principal)
        && request.offer.binding.host_id == principal
        && assignment.lease_id.is_none();
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "source upload lost its exact persisted offer authority",
        ))
    }
}

pub(super) fn require_upload_assignment_without_content(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    principal: &str,
) -> Result<(), CliError> {
    let exact = assignment.state == TaskBoardRemoteAssignmentState::Offered
        && assignment.offer.as_ref() == Some(offer)
        && assignment.authenticated_principal.as_deref() == Some(principal)
        && offer.binding.host_id == principal
        && assignment.lease_id.is_none();
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "source recovery lost its exact persisted offer authority",
        ))
    }
}
