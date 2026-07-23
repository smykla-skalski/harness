use serde::Serialize;

use super::wire::{
    RemoteArtifactFetchRequest, RemoteAssignmentWireState, RemoteCancelRequest, RemoteClaimRequest,
    RemoteHeartbeatRequest, RemoteLeaseRenewRequest, RemoteOfferRequest, RemoteSettledRequest,
    RemoteStatusRequest, RemoteWireError, domain_digest, require_canonical_time, require_digest,
    require_text, require_version, valid_artifact_path,
};
use super::wire_limits::{MAX_REMOTE_OFFER_JSON_BYTES, require_serialized_size};

macro_rules! impl_request_digest {
    ($type:ty, $validate_payload:expr) => {
        impl $type {
            pub(crate) fn seal(mut self) -> Result<Self, RemoteWireError> {
                self.request_sha256.clear();
                self.request_sha256 = request_digest(&self)?;
                Ok(self)
            }

            pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
                require_version(self.schema_version)?;
                ($validate_payload)(self)?;
                let mut unsigned = self.clone();
                unsigned.request_sha256.clear();
                let expected = request_digest(&unsigned)?;
                if self.request_sha256 != expected {
                    return Err(RemoteWireError::DigestMismatch("request_sha256"));
                }
                Ok(())
            }
        }
    };
}

impl RemoteHeartbeatRequest {
    #[cfg(test)]
    pub(crate) fn seal(mut self) -> Result<Self, RemoteWireError> {
        self.request_sha256.clear();
        self.request_sha256 = request_digest(&self)?;
        Ok(self)
    }

    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        require_text("host_id", &self.host_id)?;
        require_text("host_instance_id", &self.host_instance_id)?;
        require_canonical_time("sent_at", &self.sent_at)?;
        let mut unsigned = self.clone();
        unsigned.request_sha256.clear();
        if self.request_sha256 != request_digest(&unsigned)? {
            return Err(RemoteWireError::DigestMismatch("request_sha256"));
        }
        Ok(())
    }
}
impl_request_digest!(RemoteOfferRequest, |value: &RemoteOfferRequest| {
    value.binding.validate()?;
    value.launch.validate(&value.binding)?;
    if value.lease_seconds == 0 || value.lease_seconds > 3_600 {
        return Err(RemoteWireError::MissingField("lease_seconds"));
    }
    require_canonical_time("deadline_at", &value.deadline_at)?;
    value.artifacts.validate()?;
    value.source.validate(&value.binding, &value.artifacts)?;
    require_serialized_size("offer_request", value, MAX_REMOTE_OFFER_JSON_BYTES)
});
impl_request_digest!(RemoteClaimRequest, |value: &RemoteClaimRequest| {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)
});
impl_request_digest!(RemoteStatusRequest, |value: &RemoteStatusRequest| {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)
});
impl_request_digest!(
    RemoteLeaseRenewRequest,
    |value: &RemoteLeaseRenewRequest| {
        value.binding.validate()?;
        require_text("lease_id", &value.lease_id)?;
        require_digest("offer_request_sha256", &value.offer_request_sha256)?;
        if value.extend_seconds == 0 || value.extend_seconds > 3_600 {
            return Err(RemoteWireError::MissingField("extend_seconds"));
        }
        Ok(())
    }
);
impl_request_digest!(RemoteCancelRequest, |value: &RemoteCancelRequest| {
    value.binding.validate()?;
    require_text("lease_id", &value.lease_id)?;
    require_digest("offer_request_sha256", &value.offer_request_sha256)?;
    require_text("reason", &value.reason)?;
    if value.reason.len() > 4_096 {
        return Err(RemoteWireError::MissingField("bounded_reason"));
    }
    Ok(())
});
impl_request_digest!(RemoteSettledRequest, |value: &RemoteSettledRequest| {
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
});
impl_request_digest!(
    RemoteArtifactFetchRequest,
    |value: &RemoteArtifactFetchRequest| {
        value.binding.validate()?;
        require_text("lease_id", &value.lease_id)?;
        require_digest("offer_request_sha256", &value.offer_request_sha256)?;
        if !valid_artifact_path(&value.relative_path) {
            return Err(RemoteWireError::InvalidManifest);
        }
        require_digest("expected_sha256", &value.expected_sha256)
    }
);

fn request_digest<T: Serialize>(value: &T) -> Result<String, RemoteWireError> {
    domain_digest("harness.task-board.remote-request.v1", value)
}
