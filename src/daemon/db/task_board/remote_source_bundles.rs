use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_inbox::{
    local_checkout_path, local_host_in_tx, local_host_is_provisioned_in_tx,
};
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, load_offer_collision_in_tx,
    nonblank, to_i64,
};
use super::remote_offer_receipts::load_offer_receipt_collisions_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteOfferRequest, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse,
};

#[path = "remote_source_bundles/coordinates.rs"]
mod coordinates;
pub(super) use coordinates::source_bundle_coordinates;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteSourceBundle {
    pub(crate) offer: RemoteOfferRequest,
    pub(crate) upload_request_sha256: String,
    pub(crate) authenticated_principal: String,
    pub(crate) response: RemoteSourceBundleUploadResponse,
    pub(crate) content: Option<Vec<u8>>,
    pub(crate) content_pruned_at: Option<String>,
}

impl TaskBoardRemoteSourceBundle {
    pub(super) fn is_exact_replay(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        principal: &str,
    ) -> bool {
        self.offer == request.offer
            && self.upload_request_sha256 == request.request_sha256
            && self.authenticated_principal == principal
            && request.validate().is_ok()
    }

    pub(crate) fn materialized_request(&self) -> Result<RemoteSourceBundleUploadRequest, CliError> {
        let content = self.content.as_ref().ok_or_else(|| {
            concurrent("remote source bundle bytes were durably pruned after cleanup")
        })?;
        RemoteSourceBundleUploadRequest::seal(self.offer.clone(), content)
            .map_err(|error| db_error(format!("rebuild remote source bundle request: {error}")))
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn store_task_board_remote_source_bundle(
        &self,
        request: &RemoteSourceBundleUploadRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteSourceBundle, CliError> {
        validate_upload(
            request,
            authenticated_principal,
            host_instance_id,
            stored_at,
        )?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote source bundle upload")
            .await?;
        if !super::remote_source_bundle_abandonment::load_abandonment_collisions_in_tx(
            &mut transaction,
            &request.offer,
            &request.request_sha256,
        )
        .await?
        .is_empty()
        {
            return Err(concurrent(
                "remote source bundle generation was durably abandoned",
            ));
        }
        let collisions =
            load_source_bundle_collisions_in_tx(&mut transaction, &request.offer).await?;
        if let [existing] = collisions.as_slice() {
            if existing.is_exact_replay(request, authenticated_principal) {
                transaction.commit().await.map_err(|error| {
                    db_error(format!("commit replayed remote source bundle: {error}"))
                })?;
                return Ok(existing.clone());
            }
        }
        if !collisions.is_empty() {
            return Err(concurrent(
                "remote source bundle conflicts with immutable generation evidence",
            ));
        }
        // A source upload introduces immutable bytes before any assignment row
        // exists, so it must fence its offer identity against archived legacy
        // assignments too - past the exact source replay, before host and insert.
        require_no_archival_collision_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            &request.offer.binding.idempotency_key,
            Some(&request.offer.request_sha256),
            &request.offer.binding.execution_id,
            request.offer.binding.fencing_epoch,
        )
        .await?;
        // A pre-offer upload may not alias any live remote assignment or offer
        // receipt on assignment id, idempotency key, request digest, exact
        // attempt, or (execution_id, fencing_epoch) generation. Any live collision
        // is a hard conflict here - no replay resolution - so the bytes can never
        // be stranded by a later offer rejection that carries no reclaimable
        // receipt. SELECT_COLLISION now covers execution+epoch so an Offered
        // controller row with no receipt yet is caught on the assignment side.
        if !load_offer_collision_in_tx(&mut transaction, &request.offer)
            .await?
            .is_empty()
            || !load_offer_receipt_collisions_in_tx(&mut transaction, &request.offer)
                .await?
                .is_empty()
        {
            return Err(concurrent(
                "remote source bundle offer identity conflicts with a live assignment or receipt",
            ));
        }
        if request.offer.binding.host_instance_id != host_instance_id {
            return Err(concurrent(
                "remote source bundle targets a different executor process",
            ));
        }
        require_no_offer_in_tx(&mut transaction, &request.offer).await?;
        require_eligible_local_host_in_tx(&mut transaction, request, host_instance_id).await?;
        let response = RemoteSourceBundleUploadResponse::seal(request, stored_at.to_owned())
            .map_err(|error| db_error(format!("seal remote source bundle receipt: {error}")))?;
        insert_source_bundle_in_tx(
            &mut transaction,
            request,
            authenticated_principal,
            &response,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let stored = load_source_bundle_in_tx(
            &mut transaction,
            &request.offer.binding.assignment_id,
            request.offer.binding.fencing_epoch,
        )
        .await?
        .ok_or_else(|| db_error("persisted remote source bundle disappeared"))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote source bundle: {error}")))?;
        Ok(stored)
    }

    pub(crate) async fn task_board_remote_source_bundle(
        &self,
        assignment: &TaskBoardRemoteAssignmentRecord,
    ) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote source bundle load: {error}")))?;
        let stored = load_source_bundle_in_tx(
            &mut transaction,
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?;
        if let Some(stored) = stored.as_ref() {
            let offer = assignment.require_offer()?;
            let exact = stored.offer == *offer
                && assignment.authenticated_principal.as_deref()
                    == Some(stored.authenticated_principal.as_str());
            if !exact {
                return Err(concurrent(
                    "remote source bundle changed from its accepted assignment",
                ));
            }
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote source bundle load: {error}")))?;
        Ok(stored)
    }
}

pub(super) async fn require_source_bundle_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
    authenticated_principal: &str,
) -> Result<(), CliError> {
    if !offer.source.requires_upload() {
        return Ok(());
    }
    let collisions = load_source_bundle_collisions_in_tx(transaction, offer).await?;
    let [stored] = collisions.as_slice() else {
        return Err(concurrent(
            "remote prior-phase source bundle is not durably available",
        ));
    };
    let expected = stored.materialized_request()?;
    if stored.is_exact_replay(&expected, authenticated_principal) {
        Ok(())
    } else {
        Err(concurrent(
            "remote prior-phase source bundle conflicts with the exact offer",
        ))
    }
}

fn validate_upload(
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
    host_instance_id: &str,
    stored_at: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote source bundle upload: {error}")))?;
    nonblank(principal, "remote source bundle authenticated principal")?;
    nonblank(host_instance_id, "remote source bundle host instance")?;
    canonical_time(stored_at, "remote source bundle stored time")?;
    if principal.len() > 256 {
        return Err(concurrent(
            "remote source bundle credential or target identity mismatched",
        ));
    }
    Ok(())
}

async fn require_eligible_local_host_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    host_instance_id: &str,
) -> Result<(), CliError> {
    let (host, settings_revision) = local_host_in_tx(transaction).await?;
    let eligible = local_checkout_path(&host, &request.offer, host_instance_id)?.is_some()
        && local_host_is_provisioned_in_tx(transaction, &host, settings_revision).await?;
    if eligible {
        Ok(())
    } else {
        Err(concurrent(
            "remote source bundle targets an unavailable executor configuration",
        ))
    }
}

async fn require_no_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
) -> Result<(), CliError> {
    let exists = query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM task_board_remote_assignments WHERE assignment_id = ?1
           UNION ALL
           SELECT 1 FROM task_board_remote_offer_receipts WHERE assignment_id = ?1
         )",
    )
    .bind(&offer.binding.assignment_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "check remote source bundle offer collision: {error}"
        ))
    })?;
    if exists {
        Err(concurrent(
            "remote source bundle cannot be introduced after offer settlement",
        ))
    } else {
        Ok(())
    }
}

#[derive(sqlx::FromRow)]
struct RemoteSourceBundleRow {
    offer_json: String,
    upload_request_sha256: String,
    authenticated_principal: String,
    source_kind: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    response_json: String,
    relative_path: String,
    sha256: String,
    size_bytes: i64,
    media_type: String,
    content: Vec<u8>,
    content_pruned_at: Option<String>,
}

impl RemoteSourceBundleRow {
    fn into_bundle(self) -> Result<TaskBoardRemoteSourceBundle, CliError> {
        let offer = serde_json::from_str::<RemoteOfferRequest>(&self.offer_json)
            .map_err(|error| db_error(format!("decode remote source bundle offer: {error}")))?;
        offer
            .validate()
            .map_err(|error| db_error(format!("validate remote source bundle offer: {error}")))?;
        let size_bytes = u64::try_from(self.size_bytes)
            .map_err(|_| db_error("remote source bundle size is invalid"))?;
        let artifact = RemoteArtifactEntry {
            relative_path: self.relative_path,
            sha256: self.sha256,
            size_bytes,
            media_type: self.media_type,
        };
        let source = source_bundle_coordinates(&offer.source)?;
        let exact_source = self.source_kind == source.kind
            && self.base_revision == source.base_revision
            && self.result_revision == source.result_revision
            && self.advertised_ref == source.advertised_ref
            && &artifact == source.bundle;
        if !exact_source {
            return Err(db_error(
                "remote source bundle columns contradict the sealed source material",
            ));
        }
        let response = serde_json::from_str::<RemoteSourceBundleUploadResponse>(
            &self.response_json,
        )
        .map_err(|error| db_error(format!("decode remote source bundle response: {error}")))?;
        response
            .validate_receipt(
                &offer.binding,
                &offer.request_sha256,
                &self.upload_request_sha256,
                &artifact,
            )
            .map_err(|error| {
                db_error(format!("validate remote source bundle response: {error}"))
            })?;
        nonblank(
            &self.authenticated_principal,
            "remote source bundle authenticated principal",
        )?;
        let content = match self.content_pruned_at.as_deref() {
            None => {
                let request = RemoteSourceBundleUploadRequest::seal(offer.clone(), &self.content)
                    .map_err(|error| {
                    db_error(format!("validate remote source bundle bytes: {error}"))
                })?;
                if request.request_sha256 != self.upload_request_sha256 {
                    return Err(db_error(
                        "remote source bundle request digest is inconsistent",
                    ));
                }
                Some(self.content)
            }
            Some(pruned_at) => {
                canonical_time(pruned_at, "remote source bundle prune time")?;
                if !self.content.is_empty() {
                    return Err(db_error(
                        "pruned remote source bundle retained content bytes",
                    ));
                }
                None
            }
        };
        Ok(TaskBoardRemoteSourceBundle {
            offer,
            upload_request_sha256: self.upload_request_sha256,
            authenticated_principal: self.authenticated_principal,
            response,
            content,
            content_pruned_at: self.content_pruned_at,
        })
    }
}

pub(super) async fn load_source_bundle_collisions_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
) -> Result<Vec<TaskBoardRemoteSourceBundle>, CliError> {
    query_as::<_, RemoteSourceBundleRow>(
        "SELECT offer_json, upload_request_sha256, authenticated_principal,
                source_kind, base_revision, result_revision, advertised_ref,
                response_json, relative_path, sha256, size_bytes, media_type,
                content, content_pruned_at
         FROM task_board_remote_source_bundles
         WHERE assignment_id = ?1 OR offer_request_sha256 = ?2
         ORDER BY assignment_id, fencing_epoch",
    )
    .bind(&offer.binding.assignment_id)
    .bind(&offer.request_sha256)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote source bundle collision: {error}")))?
    .into_iter()
    .map(RemoteSourceBundleRow::into_bundle)
    .collect()
}

pub(super) async fn load_source_bundle_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<Option<TaskBoardRemoteSourceBundle>, CliError> {
    query_as::<_, RemoteSourceBundleRow>(
        "SELECT offer_json, upload_request_sha256, authenticated_principal,
                source_kind, base_revision, result_revision, advertised_ref,
                response_json, relative_path, sha256, size_bytes, media_type,
                content, content_pruned_at
         FROM task_board_remote_source_bundles
         WHERE assignment_id = ?1 AND fencing_epoch = ?2",
    )
    .bind(assignment_id)
    .bind(to_i64(fencing_epoch, "source bundle load fencing epoch")?)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote source bundle: {error}")))?
    .map(RemoteSourceBundleRow::into_bundle)
    .transpose()
}

pub(super) async fn insert_source_bundle_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleUploadRequest,
    principal: &str,
    response: &RemoteSourceBundleUploadResponse,
) -> Result<(), CliError> {
    let offer_json = serde_json::to_string(&request.offer)
        .map_err(|error| db_error(format!("serialize remote source bundle offer: {error}")))?;
    let response_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize remote source bundle response: {error}")))?;
    let content = request
        .validate()
        .map_err(|error| db_error(format!("decode remote source bundle content: {error}")))?;
    let source = source_bundle_coordinates(&request.offer.source)?;
    let binding = &request.offer.binding;
    query(
        "INSERT INTO task_board_remote_source_bundles (
           assignment_id, fencing_epoch, execution_id, action_key, attempt,
           idempotency_key, host_id, target_host_instance_id, offer_request_sha256,
           offer_json, upload_request_sha256, authenticated_principal, source_kind,
           base_revision, result_revision, advertised_ref, relative_path, sha256,
           size_bytes, media_type, content, response_json, stored_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
           ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23
         )",
    )
    .bind(&binding.assignment_id)
    .bind(to_i64(
        binding.fencing_epoch,
        "source bundle insert fencing epoch",
    )?)
    .bind(&binding.execution_id)
    .bind(&binding.action_key)
    .bind(i64::from(binding.attempt))
    .bind(&binding.idempotency_key)
    .bind(&binding.host_id)
    .bind(&binding.host_instance_id)
    .bind(&request.offer.request_sha256)
    .bind(offer_json)
    .bind(&request.request_sha256)
    .bind(principal)
    .bind(source.kind)
    .bind(source.base_revision)
    .bind(source.result_revision)
    .bind(source.advertised_ref)
    .bind(&source.bundle.relative_path)
    .bind(&source.bundle.sha256)
    .bind(to_i64(source.bundle.size_bytes, "source bundle size")?)
    .bind(&source.bundle.media_type)
    .bind(content)
    .bind(response_json)
    .bind(&response.stored_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist remote source bundle: {error}")))
}
