use sqlx::{Sqlite, Transaction};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_inbox::local_host_in_tx;
use super::remote_assignment_model::{
    canonical_time, concurrent, load_offer_collision_in_tx, nonblank,
};
use super::remote_offer_receipts::load_offer_receipt_collisions_in_tx;
use super::remote_source_bundles::load_source_bundle_collisions_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAttemptBinding, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse, RemoteSourceBundleUploadRequest,
};

#[path = "remote_source_bundle_abandonment/storage.rs"]
mod storage;
pub(super) use storage::{
    insert_abandonment_in_tx, load_abandonment_collisions_in_tx,
    load_abandonment_in_tx, source_offer_is_abandoned_in_tx,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteSourceBundleAbandonment {
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) upload_request_sha256: String,
    pub(crate) verified_absence_sha256: String,
    pub(crate) abandon_request_sha256: String,
    pub(crate) authenticated_principal: String,
    pub(crate) request: RemoteSourceBundleAbandonRequest,
    pub(crate) response: RemoteSourceBundleAbandonResponse,
}

impl TaskBoardRemoteSourceBundleAbandonment {
    pub(crate) fn is_exact_replay(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        principal: &str,
    ) -> bool {
        self.request == *request
            && self.binding == request.offer.binding
            && self.offer_request_sha256 == request.offer.request_sha256
            && self.upload_request_sha256 == request.upload_request_sha256
            && self.verified_absence_sha256 == request.verified_absence.response_sha256
            && self.abandon_request_sha256 == request.request_sha256
            && self.authenticated_principal == principal
    }

    pub(crate) fn matches_upload(
        &self,
        upload: &RemoteSourceBundleUploadRequest,
        principal: &str,
    ) -> bool {
        self.request.offer == upload.offer
            && self.request.upload_request_sha256 == upload.request_sha256
            && self.authenticated_principal == principal
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn exact_task_board_remote_source_bundle_abandonment(
        &self,
        upload: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
        upload
            .validate()
            .map_err(|error| db_error(format!("validate source abandonment lookup: {error}")))?;
        nonblank(authenticated_principal, "source abandonment lookup principal")?;
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin source abandonment lookup: {error}"))
        })?;
        let collisions = load_abandonment_collisions_in_tx(
            &mut transaction,
            &upload.offer,
            &upload.request_sha256,
        )
        .await?;
        let stored = exact_upload_abandonment(collisions, upload, authenticated_principal)?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit source abandonment lookup: {error}"))
        })?;
        Ok(stored)
    }

    pub(crate) async fn verify_task_board_remote_source_bundle_receipt(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        checked_at: &str,
    ) -> Result<RemoteSourceBundleReceiptVerificationResponse, CliError> {
        validate_executor_identity(
            request.offer.binding.host_id.as_str(),
            authenticated_principal,
            observed_host_instance_id,
            checked_at,
        )?;
        request
            .validate()
            .map_err(|error| db_error(format!("validate source receipt verification: {error}")))?;
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin source receipt verification: {error}"))
        })?;
        require_current_local_host_in_tx(
            &mut transaction,
            &request.offer.binding.host_id,
            authenticated_principal,
        )
        .await?;
        let abandonments = load_abandonment_collisions_in_tx(
            &mut transaction,
            &request.offer,
            &request.request_sha256,
        )
        .await?;
        if let Some(stored) = exact_upload_abandonment(
            abandonments,
            request,
            authenticated_principal,
        )? {
            let verification = stored.request.verified_absence;
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed source absence verification: {error}"))
            })?;
            return Ok(verification);
        }
        let collisions = load_source_bundle_collisions_in_tx(&mut transaction, &request.offer)
            .await?;
        let receipt = match collisions.as_slice() {
            [] => None,
            [stored] if stored.is_exact_replay(request, authenticated_principal) => {
                Some(stored.response.clone())
            }
            _ => {
                return Err(concurrent(
                    "source receipt verification found conflicting generation evidence",
                ));
            }
        };
        let response = RemoteSourceBundleReceiptVerificationResponse::seal(
            request,
            observed_host_instance_id.into(),
            checked_at.into(),
            receipt,
        )
        .map_err(|error| db_error(format!("seal source receipt verification: {error}")))?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit source receipt verification: {error}"))
        })?;
        Ok(response)
    }

    pub(crate) async fn abandon_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
        authenticated_principal: &str,
        observed_host_instance_id: &str,
        abandoned_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate source abandonment: {error}")))?;
        validate_executor_identity(
            request.offer.binding.host_id.as_str(),
            authenticated_principal,
            observed_host_instance_id,
            abandoned_at,
        )?;
        if request.verified_absence.observed_host_instance_id != observed_host_instance_id {
            return Err(concurrent(
                "source abandonment verification targets another executor instance",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board remote source abandonment")
            .await?;
        require_current_local_host_in_tx(
            &mut transaction,
            &request.offer.binding.host_id,
            authenticated_principal,
        )
        .await?;
        let abandonments = load_abandonment_collisions_in_tx(
            &mut transaction,
            &request.offer,
            &request.upload_request_sha256,
        )
        .await?;
        if let Some(existing) = exact_abandonment(
            abandonments,
            request,
            authenticated_principal,
        )? {
            transaction.commit().await.map_err(|error| {
                db_error(format!("commit replayed source abandonment: {error}"))
            })?;
            return Ok(existing);
        }
        // Past the exact-abandonment replay, the offer identity must not collide
        // with an archived legacy assignment before sealing new evidence.
        require_no_archival_collision_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            &request.offer.binding.idempotency_key,
            Some(&request.offer.request_sha256),
            &request.offer.binding.execution_id,
            request.offer.binding.fencing_epoch,
        )
        .await?;
        require_abandonable_generation_in_tx(&mut transaction, request).await?;
        let response = RemoteSourceBundleAbandonResponse::seal(
            request,
            observed_host_instance_id.into(),
            abandoned_at.into(),
        )
        .map_err(|error| db_error(format!("seal source abandonment response: {error}")))?;
        insert_abandonment_in_tx(
            &mut transaction,
            request,
            authenticated_principal,
            &response,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let stored = load_abandonment_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            request.offer.binding.fencing_epoch,
        )
        .await?
        .ok_or_else(|| db_error("persisted source abandonment disappeared"))?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit source abandonment: {error}"))
        })?;
        Ok(stored)
    }
}

fn exact_upload_abandonment(
    collisions: Vec<TaskBoardRemoteSourceBundleAbandonment>,
    upload: &RemoteSourceBundleUploadRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    match collisions.as_slice() {
        [] => Ok(None),
        [stored] if stored.matches_upload(upload, principal) => Ok(Some(stored.clone())),
        _ => Err(concurrent(
            "source abandonment identity, upload, or principal conflicts",
        )),
    }
}

async fn require_current_local_host_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_host_id: &str,
    principal: &str,
) -> Result<(), CliError> {
    let (host, _) = local_host_in_tx(transaction).await?;
    if host.host_id == expected_host_id && host.host_id == principal {
        Ok(())
    } else {
        Err(concurrent(
            "source recovery does not match the current configured executor host",
        ))
    }
}

async fn require_abandonable_generation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
) -> Result<(), CliError> {
    if !load_source_bundle_collisions_in_tx(transaction, &request.offer)
        .await?
        .is_empty()
    {
        return Err(concurrent(
            "source abandonment lost a race with an immutable upload receipt",
        ));
    }
    if !load_offer_collision_in_tx(transaction, &request.offer)
        .await?
        .is_empty()
        || !load_offer_receipt_collisions_in_tx(transaction, &request.offer)
            .await?
            .is_empty()
    {
        return Err(concurrent(
            "source abandonment lost a race with remote offer acceptance",
        ));
    }
    Ok(())
}

fn validate_executor_identity(
    expected_host_id: &str,
    principal: &str,
    instance: &str,
    timestamp: &str,
) -> Result<(), CliError> {
    nonblank(principal, "source recovery authenticated principal")?;
    nonblank(instance, "source recovery executor instance")?;
    canonical_time(timestamp, "source recovery time")?;
    if principal == expected_host_id && principal.len() <= 256 && instance.len() <= 256 {
        Ok(())
    } else {
        Err(concurrent(
            "source recovery credential or host identity mismatched",
        ))
    }
}

fn exact_abandonment(
    collisions: Vec<TaskBoardRemoteSourceBundleAbandonment>,
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    match collisions.as_slice() {
        [] => Ok(None),
        [stored]
            if stored.is_exact_replay(request, principal) =>
        {
            Ok(Some(stored.clone()))
        }
        _ => Err(concurrent(
            "source abandonment identity, generation, principal, or digest conflicts",
        )),
    }
}
