use serde::Serialize;

use super::wire::RemoteWireError;
use super::wire_artifacts::MAX_REMOTE_ARTIFACT_BYTES;

pub(crate) const MAX_REMOTE_RECEIPT_JSON_BYTES: usize = 16 * 1024;
pub(crate) const MAX_REMOTE_LIFECYCLE_JSON_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_REMOTE_OFFER_JSON_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES: usize =
    2 * MAX_REMOTE_RECEIPT_JSON_BYTES;

const SOURCE_BUNDLE_BASE64_BYTES: usize =
    (MAX_REMOTE_ARTIFACT_BYTES as usize).div_ceil(3) * 4;
const SOURCE_BUNDLE_PREFIX: &str = "{\"schema_version\":1,\"offer\":";
const SOURCE_BUNDLE_CONTENT_PREFIX: &str = ",\"content_base64\":\"";
const SOURCE_BUNDLE_DIGEST_PREFIX: &str = "\",\"request_sha256\":\"";
const SOURCE_BUNDLE_SUFFIX: &str = "\"}";

// `RemoteOfferRequest` has its own encoded boundary. These literal fragments
// are the exact compact serde JSON framing around that offer, the maximum
// base64 body, and the 64-byte lowercase request digest.
pub(crate) const MAX_REMOTE_SOURCE_BUNDLE_JSON_BYTES: usize = SOURCE_BUNDLE_PREFIX.len()
    + MAX_REMOTE_OFFER_JSON_BYTES
    + SOURCE_BUNDLE_CONTENT_PREFIX.len()
    + SOURCE_BUNDLE_BASE64_BYTES
    + SOURCE_BUNDLE_DIGEST_PREFIX.len()
    + 64
    + SOURCE_BUNDLE_SUFFIX.len();

const SOURCE_ABANDON_PREFIX: &str = "{\"schema_version\":1,\"offer\":";
const SOURCE_ABANDON_UPLOAD_PREFIX: &str = ",\"upload_request_sha256\":\"";
const SOURCE_ABANDON_VERIFICATION_PREFIX: &str = "\",\"verified_absence\":";
const SOURCE_ABANDON_REASON_PREFIX: &str = ",\"reason\":\"";
const SOURCE_ABANDON_REASON: &str = "executor_instance_replaced";
const SOURCE_ABANDON_DIGEST_PREFIX: &str = "\",\"request_sha256\":\"";
const SOURCE_ABANDON_SUFFIX: &str = "\"}";

pub(crate) const MAX_REMOTE_SOURCE_ABANDON_JSON_BYTES: usize = SOURCE_ABANDON_PREFIX.len()
    + MAX_REMOTE_OFFER_JSON_BYTES
    + SOURCE_ABANDON_UPLOAD_PREFIX.len()
    + 64
    + SOURCE_ABANDON_VERIFICATION_PREFIX.len()
    + MAX_REMOTE_SOURCE_RECOVERY_RESPONSE_JSON_BYTES
    + SOURCE_ABANDON_REASON_PREFIX.len()
    + SOURCE_ABANDON_REASON.len()
    + SOURCE_ABANDON_DIGEST_PREFIX.len()
    + 64
    + SOURCE_ABANDON_SUFFIX.len();

pub(super) fn require_serialized_size<T: Serialize>(
    field: &'static str,
    value: &T,
    max_bytes: usize,
) -> Result<(), RemoteWireError> {
    let bytes = serde_json::to_vec(value).map_err(|_| RemoteWireError::Serialization)?;
    if bytes.len() <= max_bytes {
        Ok(())
    } else {
        Err(RemoteWireError::EnvelopeTooLarge(field))
    }
}
