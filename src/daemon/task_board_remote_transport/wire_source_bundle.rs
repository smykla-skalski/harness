use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAttemptBinding, RemoteOfferRequest,
    RemoteSourceMaterial, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, domain_digest,
    require_canonical_time, require_digest, require_version,
};
use super::wire_limits::{
    MAX_REMOTE_RECEIPT_JSON_BYTES, MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES, require_serialized_size,
};

const SOURCE_BUNDLE_UPLOAD_DOMAIN: &str = "harness.task-board.remote-source-bundle-upload.v1";
const SOURCE_BUNDLE_RESPONSE_DOMAIN: &str = "harness.task-board.remote-source-bundle-response.v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSourceBundleUploadRequest {
    pub(crate) schema_version: u32,
    pub(crate) offer: RemoteOfferRequest,
    pub(crate) content_base64: String,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSourceBundleUploadResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) upload_request_sha256: String,
    pub(crate) artifact: RemoteArtifactEntry,
    pub(crate) stored_at: String,
    pub(crate) response_sha256: String,
}

impl RemoteSourceBundleUploadRequest {
    pub(crate) fn seal(offer: RemoteOfferRequest, content: &[u8]) -> Result<Self, RemoteWireError> {
        offer.validate()?;
        let artifact = source_bundle_entry(&offer)?;
        require_bundle_content(artifact, content)?;
        let mut request = Self {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            offer,
            content_base64: base64::engine::general_purpose::STANDARD.encode(content),
            request_sha256: String::new(),
        };
        request.request_sha256 = source_bundle_request_digest(&request)?;
        require_serialized_size(
            "source_bundle_upload_request",
            &request,
            MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES,
        )?;
        Ok(request)
    }

    pub(crate) fn validate(&self) -> Result<Vec<u8>, RemoteWireError> {
        require_version(self.schema_version)?;
        self.offer.validate()?;
        require_digest("source_bundle_request_sha256", &self.request_sha256)?;
        let artifact = source_bundle_entry(&self.offer)?;
        let expected_encoded_len = artifact
            .size_bytes
            .checked_add(2)
            .and_then(|size| size.checked_div(3))
            .and_then(|size| size.checked_mul(4))
            .and_then(|size| usize::try_from(size).ok())
            .ok_or(RemoteWireError::InvalidSourceMaterial)?;
        if self.content_base64.len() != expected_encoded_len {
            return Err(RemoteWireError::InvalidSourceMaterial);
        }
        let content = base64::engine::general_purpose::STANDARD
            .decode(&self.content_base64)
            .map_err(|_| RemoteWireError::InvalidSourceMaterial)?;
        require_bundle_content(artifact, &content)?;
        if source_bundle_request_digest(self)? != self.request_sha256 {
            return Err(RemoteWireError::DigestMismatch(
                "source_bundle_request_sha256",
            ));
        }
        require_serialized_size(
            "source_bundle_upload_request",
            self,
            MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES,
        )?;
        Ok(content)
    }

    pub(crate) fn artifact(&self) -> Result<&RemoteArtifactEntry, RemoteWireError> {
        source_bundle_entry(&self.offer)
    }
}

impl RemoteSourceBundleUploadResponse {
    pub(crate) fn seal(
        expected: &RemoteSourceBundleUploadRequest,
        stored_at: String,
    ) -> Result<Self, RemoteWireError> {
        expected.validate()?;
        require_canonical_time("source_bundle_stored_at", &stored_at)?;
        let mut response = Self {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding: expected.offer.binding.clone(),
            offer_request_sha256: expected.offer.request_sha256.clone(),
            upload_request_sha256: expected.request_sha256.clone(),
            artifact: expected.artifact()?.clone(),
            stored_at,
            response_sha256: String::new(),
        };
        response.response_sha256 = source_bundle_response_digest(&response)?;
        require_serialized_size(
            "source_bundle_upload_response",
            &response,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )?;
        Ok(response)
    }

    pub(crate) fn validate(
        &self,
        expected: &RemoteSourceBundleUploadRequest,
    ) -> Result<(), RemoteWireError> {
        self.validate_receipt(
            &expected.offer.binding,
            &expected.offer.request_sha256,
            &expected.request_sha256,
            expected.artifact()?,
        )?;
        require_version(self.schema_version)?;
        expected.validate()?;
        Ok(())
    }

    pub(crate) fn validate_receipt(
        &self,
        binding: &RemoteAttemptBinding,
        offer_request_sha256: &str,
        upload_request_sha256: &str,
        artifact: &RemoteArtifactEntry,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        binding.validate()?;
        RemoteArtifactManifest {
            entries: vec![artifact.clone()],
        }
        .validate()?;
        require_digest("source_bundle_offer_request_sha256", offer_request_sha256)?;
        require_digest("source_bundle_request_sha256", upload_request_sha256)?;
        require_canonical_time("source_bundle_stored_at", &self.stored_at)?;
        require_digest("source_bundle_response_sha256", &self.response_sha256)?;
        if &self.binding != binding
            || self.offer_request_sha256 != offer_request_sha256
            || self.upload_request_sha256 != upload_request_sha256
            || &self.artifact != artifact
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        if source_bundle_response_digest(self)? != self.response_sha256 {
            return Err(RemoteWireError::DigestMismatch(
                "source_bundle_response_sha256",
            ));
        }
        require_serialized_size(
            "source_bundle_upload_response",
            self,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )
    }
}

fn source_bundle_entry(
    offer: &RemoteOfferRequest,
) -> Result<&RemoteArtifactEntry, RemoteWireError> {
    match &offer.source {
        RemoteSourceMaterial::PriorPhaseBundle { bundle, .. }
        | RemoteSourceMaterial::RepositorySnapshotBundle { bundle, .. } => Ok(bundle),
        RemoteSourceMaterial::Repository { .. } => Err(RemoteWireError::InvalidSourceMaterial),
    }
}

fn require_bundle_content(
    artifact: &RemoteArtifactEntry,
    content: &[u8],
) -> Result<(), RemoteWireError> {
    if usize::try_from(artifact.size_bytes).ok() != Some(content.len())
        || hex::encode(Sha256::digest(content)) != artifact.sha256
    {
        return Err(RemoteWireError::DigestMismatch("source_bundle_sha256"));
    }
    Ok(())
}

fn source_bundle_request_digest(
    request: &RemoteSourceBundleUploadRequest,
) -> Result<String, RemoteWireError> {
    let mut unsigned = request.clone();
    unsigned.request_sha256.clear();
    domain_digest(SOURCE_BUNDLE_UPLOAD_DOMAIN, &unsigned)
}

fn source_bundle_response_digest(
    response: &RemoteSourceBundleUploadResponse,
) -> Result<String, RemoteWireError> {
    let mut unsigned = response.clone();
    unsigned.response_sha256.clear();
    domain_digest(SOURCE_BUNDLE_RESPONSE_DOMAIN, &unsigned)
}
