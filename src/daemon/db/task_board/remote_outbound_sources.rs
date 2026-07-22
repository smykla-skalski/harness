use sqlx::{Sqlite, Transaction, query, query_as};

use super::remote_assignment_model::{canonical_time, concurrent, to_i64};
use super::remote_source_bundles::source_bundle_coordinates;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteSourceBundleUploadRequest,
};

// Full static query. The source-recovery-owned-offer predicate is inlined here and
// duplicated in the recovery queries by design: dynamic format!-built SQL stays a
// compile error so every remote query is a fully audited &'static str.
const SOURCE_RECOVERY_OWNS_OFFER_QUERY: &str =
    "SELECT EXISTS(
           SELECT 1 FROM task_board_remote_assignments AS assignments
           WHERE assignments.assignment_id = ?1 AND assignments.fencing_epoch = ?2
             AND (assignments.state = 'offered'
                  AND assignments.lease_id IS NULL
                  AND assignments.claim_receipt_sha256 IS NULL
                  AND assignments.claimed_at IS NULL
                  AND assignments.started_at IS NULL
                  AND assignments.workspace_ref IS NULL
                  AND assignments.controller_handoff_kind IS NULL
                  AND (assignments.controller_operation_kind IS NULL
                       OR assignments.controller_operation_kind IN ('upload_source_bundle', 'offer'))
                  AND EXISTS (
                    SELECT 1 FROM task_board_remote_outbound_sources AS source
                    WHERE source.assignment_id = assignments.assignment_id
                      AND source.fencing_epoch = assignments.fencing_epoch
                      AND source.offer_request_sha256 = assignments.request_sha256
                      AND source.source_kind IN ('prior_phase_bundle', 'repository_snapshot_bundle')
                      AND source.content_pruned_at IS NULL
                      AND length(source.content) = source.size_bytes
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM task_board_remote_offer_receipts AS receipt
                    WHERE receipt.assignment_id = assignments.assignment_id
                      AND receipt.fencing_epoch = assignments.fencing_epoch
                      AND receipt.request_sha256 = assignments.request_sha256
                  ))
         )";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteOutboundSource {
    pub(crate) upload: Option<RemoteSourceBundleUploadRequest>,
    pub(crate) stored_at: String,
    pub(crate) content_pruned_at: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_outbound_source_upload(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<Option<RemoteSourceBundleUploadRequest>, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin remote outbound source load: {error}"))
        })?;
        let source = load_outbound_source_in_tx(&mut transaction, assignment_id, fencing_epoch)
            .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote outbound source load: {error}"))
        })?;
        source
            .map(|source| {
                source.upload.ok_or_else(|| {
                    concurrent("remote outbound source bytes were durably pruned")
                })
            })
            .transpose()
    }

    pub(crate) async fn task_board_remote_source_recovery_owns_offer(
        &self,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        let mut transaction = self.pool().begin().await.map_err(|error| {
            db_error(format!("begin remote source ownership check: {error}"))
        })?;
        let owned = source_recovery_owns_offered_generation_in_tx(
            &mut transaction,
            assignment_id,
            fencing_epoch,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit remote source ownership check: {error}"))
        })?;
        Ok(owned)
    }
}

pub(super) async fn source_recovery_owns_offered_generation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<bool, CliError> {
    query_as::<_, (bool,)>(SOURCE_RECOVERY_OWNS_OFFER_QUERY)
        .bind(assignment_id)
        .bind(to_i64(fencing_epoch, "source ownership fencing epoch")?)
        .fetch_one(transaction.as_mut())
        .await
        .map(|(owned,)| owned)
        .map_err(|error| db_error(format!("check remote source recovery ownership: {error}")))
}

pub(super) async fn persist_outbound_source_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
    content: Option<&[u8]>,
    stored_at: &str,
) -> Result<(), CliError> {
    let required = offer.source.requires_upload();
    match (required, content) {
        (false, None) => return Ok(()),
        (false, Some(_)) => {
            return Err(db_error(
                "repository source cannot persist an outbound bundle",
            ));
        }
        (true, None) => {
            return Err(concurrent(
                "uploaded remote source has no durable controller bytes",
            ));
        }
        (true, Some(_)) => {}
    }
    canonical_time(stored_at, "remote outbound source stored time")?;
    let content = content.expect("required outbound source content");
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), content)
        .map_err(|error| db_error(format!("seal remote outbound source: {error}")))?;
    let existing = load_outbound_source_in_tx(
        transaction,
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await?;
    if let Some(existing) = existing {
        if existing.upload.as_ref() == Some(&upload) {
            return Ok(());
        }
        return Err(concurrent(
            "remote outbound source changed after durable assignment",
        ));
    }
    insert_outbound_source_in_tx(transaction, &upload, stored_at).await
}

pub(super) async fn require_outbound_source_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
    content: Option<&[u8]>,
) -> Result<(), CliError> {
    if !offer.source.requires_upload() {
        return if content.is_none() {
            Ok(())
        } else {
            Err(db_error("repository source has unexpected outbound bytes"))
        };
    }
    let expected = content
        .map(|content| RemoteSourceBundleUploadRequest::seal(offer.clone(), content))
        .transpose()
        .map_err(|error| db_error(format!("seal replayed remote outbound source: {error}")))?;
    let existing = load_outbound_source_in_tx(
        transaction,
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await?;
    if existing.as_ref().and_then(|source| source.upload.as_ref()) == expected.as_ref()
        && expected.is_some()
    {
        Ok(())
    } else {
        Err(concurrent(
            "replayed remote offer lost its exact durable source bytes",
        ))
    }
}

pub(super) async fn exact_outbound_source_content_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
) -> Result<Vec<u8>, CliError> {
    if !offer.source.requires_upload() {
        return Err(db_error(
            "repository source has no durable outbound bundle",
        ));
    }
    let source = load_outbound_source_in_tx(
        transaction,
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
    )
    .await?
    .ok_or_else(|| concurrent("remote outbound source evidence disappeared"))?;
    let upload = source
        .upload
        .ok_or_else(|| concurrent("remote outbound source bytes were durably pruned"))?;
    if upload.offer != *offer {
        return Err(concurrent(
            "remote outbound source changed from its assignment offer",
        ));
    }
    upload
        .validate()
        .map_err(|error| db_error(format!("validate exact remote outbound source: {error}")))
}

async fn insert_outbound_source_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    upload: &RemoteSourceBundleUploadRequest,
    stored_at: &str,
) -> Result<(), CliError> {
    let offer_json = serde_json::to_string(&upload.offer)
        .map_err(|error| db_error(format!("serialize remote outbound offer: {error}")))?;
    let content = upload
        .validate()
        .map_err(|error| db_error(format!("validate remote outbound source: {error}")))?;
    let source = source_bundle_coordinates(&upload.offer.source)?;
    let binding = &upload.offer.binding;
    query(
        "INSERT INTO task_board_remote_outbound_sources (
           assignment_id, fencing_epoch, execution_id, action_key, attempt,
           idempotency_key, offer_request_sha256, offer_json, upload_request_sha256,
           source_kind, repository, base_revision, result_revision, advertised_ref,
           relative_path, sha256, size_bytes, media_type, content, stored_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
           ?15, ?16, ?17, ?18, ?19, ?20
         )",
    )
    .bind(&binding.assignment_id)
    .bind(to_i64(binding.fencing_epoch, "outbound source fencing epoch")?)
    .bind(&binding.execution_id)
    .bind(&binding.action_key)
    .bind(i64::from(binding.attempt))
    .bind(&binding.idempotency_key)
    .bind(&upload.offer.request_sha256)
    .bind(offer_json)
    .bind(&upload.request_sha256)
    .bind(source.kind)
    .bind(source.repository)
    .bind(source.base_revision)
    .bind(source.result_revision)
    .bind(source.advertised_ref)
    .bind(&source.bundle.relative_path)
    .bind(&source.bundle.sha256)
    .bind(to_i64(source.bundle.size_bytes, "outbound source size")?)
    .bind(&source.bundle.media_type)
    .bind(content)
    .bind(stored_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist remote outbound source: {error}")))
}

#[derive(sqlx::FromRow)]
struct OutboundSourceRow {
    offer_json: String,
    upload_request_sha256: String,
    source_kind: String,
    repository: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    relative_path: String,
    sha256: String,
    size_bytes: i64,
    media_type: String,
    content: Vec<u8>,
    stored_at: String,
    content_pruned_at: Option<String>,
}

impl OutboundSourceRow {
    fn into_source(self) -> Result<TaskBoardRemoteOutboundSource, CliError> {
        canonical_time(&self.stored_at, "remote outbound source stored time")?;
        let offer = serde_json::from_str::<RemoteOfferRequest>(&self.offer_json)
            .map_err(|error| db_error(format!("decode remote outbound offer: {error}")))?;
        offer
            .validate()
            .map_err(|error| db_error(format!("validate remote outbound offer: {error}")))?;
        let source = source_bundle_coordinates(&offer.source)?;
        let exact = self.source_kind == source.kind
            && self.repository == source.repository
            && self.base_revision == source.base_revision
            && self.result_revision == source.result_revision
            && self.advertised_ref == source.advertised_ref
            && self.relative_path == source.bundle.relative_path
            && self.sha256 == source.bundle.sha256
            && u64::try_from(self.size_bytes).ok() == Some(source.bundle.size_bytes)
            && self.media_type == source.bundle.media_type;
        if !exact {
            return Err(db_error(
                "remote outbound source columns contradict the sealed offer",
            ));
        }
        let upload = match self.content_pruned_at.as_deref() {
            None => {
                let upload = RemoteSourceBundleUploadRequest::seal(offer, &self.content)
                    .map_err(|error| {
                        db_error(format!("validate remote outbound source bytes: {error}"))
                    })?;
                if upload.request_sha256 != self.upload_request_sha256 {
                    return Err(db_error(
                        "remote outbound source request digest is inconsistent",
                    ));
                }
                Some(upload)
            }
            Some(pruned_at) => {
                canonical_time(pruned_at, "remote outbound source prune time")?;
                if !self.content.is_empty() {
                    return Err(db_error("pruned remote outbound source retained bytes"));
                }
                None
            }
        };
        Ok(TaskBoardRemoteOutboundSource {
            upload,
            stored_at: self.stored_at,
            content_pruned_at: self.content_pruned_at,
        })
    }
}

async fn load_outbound_source_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<Option<TaskBoardRemoteOutboundSource>, CliError> {
    query_as::<_, OutboundSourceRow>(
        "SELECT offer_json, upload_request_sha256, source_kind, repository,
                base_revision, result_revision, advertised_ref, relative_path,
                sha256, size_bytes, media_type, content, stored_at, content_pruned_at
         FROM task_board_remote_outbound_sources
         WHERE assignment_id = ?1 AND fencing_epoch = ?2",
    )
    .bind(assignment_id)
    .bind(to_i64(fencing_epoch, "outbound source load fencing epoch")?)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote outbound source: {error}")))?
    .map(OutboundSourceRow::into_source)
    .transpose()
}
