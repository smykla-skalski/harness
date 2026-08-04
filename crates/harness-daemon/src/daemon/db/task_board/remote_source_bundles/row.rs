use super::super::remote_assignment_model::{canonical_time, nonblank};
use super::{TaskBoardRemoteSourceBundle, source_bundle_coordinates};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::remote_wire::wire::{
    RemoteArtifactEntry, RemoteOfferRequest, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse,
};

#[derive(sqlx::FromRow)]
pub(super) struct RemoteSourceBundleRow {
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
    pub(super) fn into_bundle(self) -> Result<TaskBoardRemoteSourceBundle, CliError> {
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
