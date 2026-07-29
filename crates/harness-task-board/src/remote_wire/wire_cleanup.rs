//! Exact executor-cleanup observation after immutable settlement.

use serde::{Deserialize, Serialize};

use super::wire::{
    RemoteAttemptBinding, RemoteSettledRequest, RemoteWireError, domain_digest,
    require_canonical_time, require_digest, require_text, require_version,
};

const CLEANUP_REQUEST_DOMAIN: &str = "harness.task-board.remote-cleanup-observation-request.v1";
const CLEANUP_RESPONSE_DOMAIN: &str = "harness.task-board.remote-cleanup-observation-response.v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteCleanupObservationRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub settlement_request_sha256: String,
    pub request_sha256: String,
}

impl RemoteCleanupObservationRequest {
    /// # Errors
    /// Returns [`RemoteWireError`] if `settlement` fails its own wire
    /// contract or the derived request cannot be sealed.
    pub fn for_settlement(settlement: &RemoteSettledRequest) -> Result<Self, RemoteWireError> {
        settlement.validate()?;
        Self {
            schema_version: settlement.schema_version,
            binding: settlement.binding.clone(),
            lease_id: settlement.lease_id.clone(),
            offer_request_sha256: settlement.offer_request_sha256.clone(),
            settlement_request_sha256: settlement.request_sha256.clone(),
            request_sha256: String::new(),
        }
        .seal()
    }

    /// # Errors
    /// Returns [`RemoteWireError::Serialization`] if the request cannot be
    /// digested.
    pub fn seal(mut self) -> Result<Self, RemoteWireError> {
        self.request_sha256.clear();
        self.request_sha256 = domain_digest(CLEANUP_REQUEST_DOMAIN, &self)?;
        Ok(self)
    }

    /// # Errors
    /// Returns [`RemoteWireError`] if the request fails its own wire
    /// contract or its digest does not match its own content.
    pub fn validate(&self) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        self.binding.validate()?;
        require_text("lease_id", &self.lease_id)?;
        require_digest("offer_request_sha256", &self.offer_request_sha256)?;
        require_digest("settlement_request_sha256", &self.settlement_request_sha256)?;
        require_digest("request_sha256", &self.request_sha256)?;
        let mut unsigned = self.clone();
        unsigned.request_sha256.clear();
        if domain_digest(CLEANUP_REQUEST_DOMAIN, &unsigned)? == self.request_sha256 {
            Ok(())
        } else {
            Err(RemoteWireError::DigestMismatch("request_sha256"))
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteCleanupObservationResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub settlement_request_sha256: String,
    pub cleanup_completed_at: String,
    pub response_sha256: String,
}

impl RemoteCleanupObservationResponse {
    /// # Errors
    /// Returns [`RemoteWireError`] if `expected` fails its own wire contract
    /// or the derived response cannot be sealed.
    pub fn for_completed(
        expected: &RemoteCleanupObservationRequest,
        cleanup_completed_at: String,
    ) -> Result<Self, RemoteWireError> {
        Self {
            schema_version: expected.schema_version,
            binding: expected.binding.clone(),
            offer_request_sha256: expected.offer_request_sha256.clone(),
            settlement_request_sha256: expected.settlement_request_sha256.clone(),
            cleanup_completed_at,
            response_sha256: String::new(),
        }
        .seal(expected)
    }

    /// # Errors
    /// Returns [`RemoteWireError`] if `expected` fails its own wire contract
    /// or the response cannot be digested.
    pub fn seal(
        mut self,
        expected: &RemoteCleanupObservationRequest,
    ) -> Result<Self, RemoteWireError> {
        expected.validate()?;
        self.response_sha256.clear();
        self.response_sha256 = response_digest(expected, &self)?;
        Ok(self)
    }

    /// # Errors
    /// Returns [`RemoteWireError`] if `expected` fails its own wire
    /// contract, this response does not echo `expected`, or its digest does
    /// not match its own content.
    pub fn validate(
        &self,
        expected: &RemoteCleanupObservationRequest,
    ) -> Result<(), RemoteWireError> {
        expected.validate()?;
        require_version(self.schema_version)?;
        self.binding.validate()?;
        require_digest("offer_request_sha256", &self.offer_request_sha256)?;
        require_digest("settlement_request_sha256", &self.settlement_request_sha256)?;
        require_canonical_time("cleanup_completed_at", &self.cleanup_completed_at)?;
        require_digest("response_sha256", &self.response_sha256)?;
        if self.binding != expected.binding
            || self.offer_request_sha256 != expected.offer_request_sha256
            || self.settlement_request_sha256 != expected.settlement_request_sha256
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        let mut unsigned = self.clone();
        unsigned.response_sha256.clear();
        if response_digest(expected, &unsigned)? == self.response_sha256 {
            Ok(())
        } else {
            Err(RemoteWireError::DigestMismatch("response_sha256"))
        }
    }
}

fn response_digest(
    expected: &RemoteCleanupObservationRequest,
    response: &RemoteCleanupObservationResponse,
) -> Result<String, RemoteWireError> {
    domain_digest(
        CLEANUP_RESPONSE_DOMAIN,
        &(&expected.request_sha256, response),
    )
}

#[cfg(test)]
#[path = "wire_cleanup_tests.rs"]
mod tests;
