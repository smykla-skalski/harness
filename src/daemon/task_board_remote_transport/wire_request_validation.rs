use serde::Serialize;

use super::wire::{
    RemoteArtifactFetchRequest, RemoteAssignmentWireState, RemoteCancelRequest, RemoteClaimRequest,
    RemoteHeartbeatRequest, RemoteLeaseRenewRequest, RemoteOfferRequest, RemoteSettledRequest,
    RemoteStatusRequest, RemoteWireError, domain_digest, require_canonical_time, require_digest,
    require_text, require_version, valid_artifact_path,
};
use super::wire_limits::{MAX_REMOTE_OFFER_JSON_BYTES, require_serialized_size};

impl RemoteHeartbeatRequest {
    #[cfg(test)]
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_heartbeat_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteOfferRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_offer_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteClaimRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_claim_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteStatusRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_status_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteLeaseRenewRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_lease_renew_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteCancelRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_cancel_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteSettledRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_settled_payload,
            |value| &mut value.request_sha256,
        )
    }
}

impl RemoteArtifactFetchRequest {
    pub(crate) fn seal(self) -> Result<Self, RemoteWireError> {
        seal_request(self, |value| &mut value.request_sha256)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        validate_request(
            self,
            self.schema_version,
            &self.request_sha256,
            validate_artifact_fetch_payload,
            |value| &mut value.request_sha256,
        )
    }
}

fn validate_heartbeat_payload(value: &RemoteHeartbeatRequest) -> Result<(), RemoteWireError> {
    require_text("host_id", &value.host_id)?;
    require_text("host_instance_id", &value.host_instance_id)?;
    require_canonical_time("sent_at", &value.sent_at)
}

fn validate_offer_payload(value: &RemoteOfferRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    value.launch.validate(&value.binding)?;
    if value.lease_seconds == 0 || value.lease_seconds > 3_600 {
        return Err(RemoteWireError::MissingField("lease_seconds"));
    }
    require_canonical_time("deadline_at", &value.deadline_at)?;
    value.artifacts.validate()?;
    value.source.validate(&value.binding, &value.artifacts)?;
    require_serialized_size("offer_request", value, MAX_REMOTE_OFFER_JSON_BYTES)
}

fn validate_claim_payload(value: &RemoteClaimRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)
}

fn validate_status_payload(value: &RemoteStatusRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)
}

fn validate_lease_renew_payload(value: &RemoteLeaseRenewRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)?;
    if value.extend_seconds == 0 || value.extend_seconds > 3_600 {
        return Err(RemoteWireError::MissingField("extend_seconds"));
    }
    Ok(())
}

fn validate_cancel_payload(value: &RemoteCancelRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)?;
    require_text("reason", &value.reason)?;
    if value.reason.len() > 4_096 {
        return Err(RemoteWireError::MissingField("bounded_reason"));
    }
    Ok(())
}

fn validate_settled_payload(value: &RemoteSettledRequest) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)?;
    if let Some(digest) = &value.result_sha256 {
        require_digest("result_sha256", digest)?;
    }
    match (value.terminal_state, value.result_sha256.is_some()) {
        (RemoteAssignmentWireState::Completed, true)
        | (
            RemoteAssignmentWireState::Failed
            | RemoteAssignmentWireState::Cancelled
            | RemoteAssignmentWireState::Superseded
            | RemoteAssignmentWireState::Unknown,
            false,
        ) => {}
        _ => return Err(RemoteWireError::ResultBindingMismatch),
    }
    Ok(())
}

fn validate_artifact_fetch_payload(
    value: &RemoteArtifactFetchRequest,
) -> Result<(), RemoteWireError> {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)?;
    if !valid_artifact_path(&value.relative_path) {
        return Err(RemoteWireError::InvalidManifest);
    }
    require_digest("expected_sha256", &value.expected_sha256)
}

fn seal_request<T: Serialize>(
    mut value: T,
    request_sha256: fn(&mut T) -> &mut String,
) -> Result<T, RemoteWireError> {
    request_sha256(&mut value).clear();
    let digest = request_digest(&value)?;
    *request_sha256(&mut value) = digest;
    Ok(value)
}

fn validate_request<T: Clone + Serialize>(
    value: &T,
    schema_version: u32,
    request_sha256: &str,
    validate_payload: fn(&T) -> Result<(), RemoteWireError>,
    unsigned_request_sha256: fn(&mut T) -> &mut String,
) -> Result<(), RemoteWireError> {
    require_version(schema_version)?;
    validate_payload(value)?;
    let mut unsigned = value.clone();
    unsigned_request_sha256(&mut unsigned).clear();
    if request_sha256 != request_digest(&unsigned)? {
        return Err(RemoteWireError::DigestMismatch("request_sha256"));
    }
    Ok(())
}

fn request_digest<T: Serialize>(value: &T) -> Result<String, RemoteWireError> {
    domain_digest("harness.task-board.remote-request.v1", value)
}
