use serde::{Deserialize, Serialize};

use super::wire::{
    RemoteAttemptBinding, RemoteOfferRequest, RemoteSourceBundleUploadRequest,
    RemoteSourceBundleUploadResponse, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
    domain_digest, require_canonical_identity, require_canonical_time, require_digest,
    require_version,
};
use super::wire_limits::{
    MAX_REMOTE_RECEIPT_JSON_BYTES, MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES,
    MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES, require_serialized_size,
};

const RECEIPT_VERIFICATION_DOMAIN: &str =
    "harness.task-board.remote-source-bundle-receipt-verification.v1";
const ABANDON_REQUEST_DOMAIN: &str =
    "harness.task-board.remote-source-bundle-abandon-request.v1";
const ABANDON_RESPONSE_DOMAIN: &str =
    "harness.task-board.remote-source-bundle-abandon-response.v1";

pub(crate) const SOURCE_BUNDLE_ABANDON_REASON: &str = "executor_instance_replaced";

#[derive(Serialize)]
struct RemoteSourceBundleAbandonAuthority<'a> {
    schema_version: u32,
    binding: &'a RemoteAttemptBinding,
    offer_request_sha256: &'a str,
    upload_request_sha256: &'a str,
    verified_absence_sha256: &'a str,
    reason: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSourceBundleReceiptVerificationResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) upload_request_sha256: String,
    pub(crate) observed_host_instance_id: String,
    pub(crate) checked_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) receipt: Option<RemoteSourceBundleUploadResponse>,
    pub(crate) response_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSourceBundleAbandonRequest {
    pub(crate) schema_version: u32,
    pub(crate) offer: RemoteOfferRequest,
    pub(crate) upload_request_sha256: String,
    pub(crate) verified_absence: RemoteSourceBundleReceiptVerificationResponse,
    pub(crate) reason: String,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSourceBundleAbandonResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) upload_request_sha256: String,
    pub(crate) abandon_request_sha256: String,
    pub(crate) abandoned_by_host_instance_id: String,
    pub(crate) abandoned_at: String,
    pub(crate) response_sha256: String,
}

impl RemoteSourceBundleReceiptVerificationResponse {
    pub(crate) fn seal(
        request: &RemoteSourceBundleUploadRequest,
        observed_host_instance_id: String,
        checked_at: String,
        receipt: Option<RemoteSourceBundleUploadResponse>,
    ) -> Result<Self, RemoteWireError> {
        request.validate()?;
        let mut response = Self {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding: request.offer.binding.clone(),
            offer_request_sha256: request.offer.request_sha256.clone(),
            upload_request_sha256: request.request_sha256.clone(),
            observed_host_instance_id,
            checked_at,
            receipt,
            response_sha256: String::new(),
        };
        response.validate_fields(request)?;
        response.response_sha256 = receipt_verification_digest(&response)?;
        require_serialized_size(
            "source_bundle_receipt_verification_response",
            &response,
            MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES,
        )?;
        Ok(response)
    }

    pub(crate) fn validate(
        &self,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<(), RemoteWireError> {
        self.validate_fields(request)?;
        require_digest(
            "source_bundle_receipt_verification_sha256",
            &self.response_sha256,
        )?;
        if receipt_verification_digest(self)? == self.response_sha256 {
            require_serialized_size(
                "source_bundle_receipt_verification_response",
                self,
                MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES,
            )
        } else {
            Err(RemoteWireError::DigestMismatch(
                "source_bundle_receipt_verification_sha256",
            ))
        }
    }

    fn validate_fields(
        &self,
        request: &RemoteSourceBundleUploadRequest,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        request.validate()?;
        require_canonical_identity(
            "source_bundle_observed_host_instance_id",
            &self.observed_host_instance_id,
            256,
        )?;
        require_canonical_time("source_bundle_receipt_checked_at", &self.checked_at)?;
        if self.binding != request.offer.binding
            || self.offer_request_sha256 != request.offer.request_sha256
            || self.upload_request_sha256 != request.request_sha256
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        if let Some(receipt) = &self.receipt {
            receipt.validate(request)?;
        }
        Ok(())
    }
}

impl RemoteSourceBundleAbandonRequest {
    pub(crate) fn seal(
        upload: &RemoteSourceBundleUploadRequest,
        verified_absence: RemoteSourceBundleReceiptVerificationResponse,
    ) -> Result<Self, RemoteWireError> {
        upload.validate()?;
        verified_absence.validate(upload)?;
        if verified_absence.receipt.is_some() {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        let mut request = Self {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            offer: upload.offer.clone(),
            upload_request_sha256: upload.request_sha256.clone(),
            verified_absence,
            reason: SOURCE_BUNDLE_ABANDON_REASON.into(),
            request_sha256: String::new(),
        };
        request.request_sha256 = abandon_request_digest(&request)?;
        require_serialized_size(
            "source_bundle_abandon_request",
            &request,
            MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES,
        )?;
        Ok(request)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        self.offer.validate()?;
        require_digest(
            "source_bundle_abandon_upload_request_sha256",
            &self.upload_request_sha256,
        )?;
        require_digest(
            "source_bundle_abandon_request_sha256",
            &self.request_sha256,
        )?;
        if self.reason != SOURCE_BUNDLE_ABANDON_REASON
            || self.verified_absence.receipt.is_some()
            || self.verified_absence.binding != self.offer.binding
            || self.verified_absence.offer_request_sha256 != self.offer.request_sha256
            || self.verified_absence.upload_request_sha256 != self.upload_request_sha256
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        require_version(self.verified_absence.schema_version)?;
        require_canonical_identity(
            "source_bundle_observed_host_instance_id",
            &self.verified_absence.observed_host_instance_id,
            256,
        )?;
        require_canonical_time(
            "source_bundle_receipt_checked_at",
            &self.verified_absence.checked_at,
        )?;
        require_digest(
            "source_bundle_receipt_verification_sha256",
            &self.verified_absence.response_sha256,
        )?;
        if receipt_verification_digest(&self.verified_absence)?
            != self.verified_absence.response_sha256
            || abandon_authority_digest(
                &self.offer.binding,
                &self.offer.request_sha256,
                &self.upload_request_sha256,
                &self.verified_absence.response_sha256,
            )? != self.request_sha256
        {
            return Err(RemoteWireError::DigestMismatch(
                "source_bundle_abandon_request_sha256",
            ));
        }
        require_serialized_size(
            "source_bundle_abandon_request",
            self,
            MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES,
        )
    }

    pub(crate) fn validate_compact_authority(
        binding: &RemoteAttemptBinding,
        offer_request_sha256: &str,
        upload_request_sha256: &str,
        verified_absence_sha256: &str,
        abandon_request_sha256: &str,
    ) -> Result<(), RemoteWireError> {
        binding.validate()?;
        require_digest("source_bundle_offer_request_sha256", offer_request_sha256)?;
        require_digest(
            "source_bundle_abandon_upload_request_sha256",
            upload_request_sha256,
        )?;
        require_digest(
            "source_bundle_receipt_verification_sha256",
            verified_absence_sha256,
        )?;
        require_digest(
            "source_bundle_abandon_request_sha256",
            abandon_request_sha256,
        )?;
        if abandon_authority_digest(
            binding,
            offer_request_sha256,
            upload_request_sha256,
            verified_absence_sha256,
        )? == abandon_request_sha256
        {
            Ok(())
        } else {
            Err(RemoteWireError::DigestMismatch(
                "source_bundle_abandon_request_sha256",
            ))
        }
    }
}

impl RemoteSourceBundleAbandonResponse {
    pub(crate) fn seal(
        request: &RemoteSourceBundleAbandonRequest,
        abandoned_by_host_instance_id: String,
        abandoned_at: String,
    ) -> Result<Self, RemoteWireError> {
        request.validate()?;
        let mut response = Self {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding: request.offer.binding.clone(),
            upload_request_sha256: request.upload_request_sha256.clone(),
            abandon_request_sha256: request.request_sha256.clone(),
            abandoned_by_host_instance_id,
            abandoned_at,
            response_sha256: String::new(),
        };
        response.validate_fields(request)?;
        response.response_sha256 = abandon_response_digest(&response)?;
        require_serialized_size(
            "source_bundle_abandon_response",
            &response,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )?;
        Ok(response)
    }

    pub(crate) fn validate(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
    ) -> Result<(), RemoteWireError> {
        self.validate_receipt(
            &request.offer.binding,
            &request.upload_request_sha256,
            &request.request_sha256,
            &request.verified_absence.observed_host_instance_id,
        )?;
        request.validate()?;
        Ok(())
    }

    pub(crate) fn validate_receipt(
        &self,
        binding: &RemoteAttemptBinding,
        upload_request_sha256: &str,
        abandon_request_sha256: &str,
        abandoned_by_host_instance_id: &str,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        require_digest(
            "source_bundle_abandon_upload_request_sha256",
            upload_request_sha256,
        )?;
        require_digest(
            "source_bundle_abandon_request_sha256",
            abandon_request_sha256,
        )?;
        require_canonical_identity(
            "source_bundle_abandoned_host_instance_id",
            abandoned_by_host_instance_id,
            256,
        )?;
        require_canonical_time("source_bundle_abandoned_at", &self.abandoned_at)?;
        require_digest(
            "source_bundle_abandon_response_sha256",
            &self.response_sha256,
        )?;
        if &self.binding != binding
            || self.upload_request_sha256 != upload_request_sha256
            || self.abandon_request_sha256 != abandon_request_sha256
            || self.abandoned_by_host_instance_id != abandoned_by_host_instance_id
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        if abandon_response_digest(self)? == self.response_sha256 {
            require_serialized_size(
                "source_bundle_abandon_response",
                self,
                MAX_REMOTE_RECEIPT_JSON_BYTES,
            )
        } else {
            Err(RemoteWireError::DigestMismatch(
                "source_bundle_abandon_response_sha256",
            ))
        }
    }

    fn validate_fields(
        &self,
        request: &RemoteSourceBundleAbandonRequest,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        request.validate()?;
        require_canonical_identity(
            "source_bundle_abandoned_host_instance_id",
            &self.abandoned_by_host_instance_id,
            256,
        )?;
        require_canonical_time("source_bundle_abandoned_at", &self.abandoned_at)?;
        if self.binding != request.offer.binding
            || self.upload_request_sha256 != request.upload_request_sha256
            || self.abandon_request_sha256 != request.request_sha256
            || self.abandoned_by_host_instance_id
                != request.verified_absence.observed_host_instance_id
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        Ok(())
    }
}

fn receipt_verification_digest(
    response: &RemoteSourceBundleReceiptVerificationResponse,
) -> Result<String, RemoteWireError> {
    let mut unsigned = response.clone();
    unsigned.response_sha256.clear();
    domain_digest(RECEIPT_VERIFICATION_DOMAIN, &unsigned)
}

fn abandon_request_digest(
    request: &RemoteSourceBundleAbandonRequest,
) -> Result<String, RemoteWireError> {
    abandon_authority_digest(
        &request.offer.binding,
        &request.offer.request_sha256,
        &request.upload_request_sha256,
        &request.verified_absence.response_sha256,
    )
}

fn abandon_authority_digest(
    binding: &RemoteAttemptBinding,
    offer_request_sha256: &str,
    upload_request_sha256: &str,
    verified_absence_sha256: &str,
) -> Result<String, RemoteWireError> {
    domain_digest(
        ABANDON_REQUEST_DOMAIN,
        &RemoteSourceBundleAbandonAuthority {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding,
            offer_request_sha256,
            upload_request_sha256,
            verified_absence_sha256,
            reason: SOURCE_BUNDLE_ABANDON_REASON,
        },
    )
}

fn abandon_response_digest(
    response: &RemoteSourceBundleAbandonResponse,
) -> Result<String, RemoteWireError> {
    let mut unsigned = response.clone();
    unsigned.response_sha256.clear();
    domain_digest(ABANDON_RESPONSE_DOMAIN, &unsigned)
}
