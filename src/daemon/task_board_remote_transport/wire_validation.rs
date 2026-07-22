use base64::Engine as _;
use sha2::{Digest, Sha256};

use super::wire::{
    RemoteArtifactFetchRequest, RemoteArtifactFetchResponse, RemoteArtifactManifest,
    RemoteAssignmentWireState, RemoteAttemptBinding, RemoteCancelRequest, RemoteCancelResponse,
    RemoteClaimRequest, RemoteClaimResponse, RemoteLease, RemoteLeaseRenewRequest,
    RemoteLeaseRenewResponse, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSettledRequest, RemoteSettledResponse, RemoteStatusRequest, RemoteStatusResponse,
    RemoteWireError, domain_digest, require_canonical_time, require_digest, require_text,
    require_version,
};
use super::wire_limits::{
    MAX_REMOTE_LIFECYCLE_JSON_BYTES, MAX_REMOTE_RECEIPT_JSON_BYTES,
    require_serialized_size,
};

impl RemoteLease {
    fn validate(&self) -> Result<(), RemoteWireError> {
        require_text("lease_id", &self.lease_id)?;
        super::wire::require_max_bytes("lease_id", &self.lease_id, 256)?;
        require_canonical_time("lease_expires_at", &self.expires_at)
    }
}

impl RemoteOfferResponse {
    pub(crate) fn validate(&self, expected: &RemoteOfferRequest) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        validate_operation_echo(
            &self.binding,
            &self.offer_request_sha256,
            &expected.binding,
            &expected.request_sha256,
        )?;
        match self.disposition {
            RemoteOfferDisposition::Accepted => {
                self.lease
                    .as_ref()
                    .ok_or(RemoteWireError::MissingField("lease"))?
                    .validate()?;
                if self.rejection_code.is_some() {
                    return Err(RemoteWireError::MissingField("accepted_rejection_code"));
                }
            }
            RemoteOfferDisposition::Rejected => {
                if self.lease.is_some() {
                    return Err(RemoteWireError::MissingField("rejected_lease"));
                }
                require_canonical_token(
                    "rejection_code",
                    self.rejection_code.as_deref().unwrap_or_default(),
                )?;
            }
        }
        require_serialized_size(
            "offer_response",
            self,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )
    }
}

fn require_canonical_token(field: &'static str, value: &str) -> Result<(), RemoteWireError> {
    let valid = (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_');
    if valid {
        Ok(())
    } else {
        Err(RemoteWireError::InvalidToken(field))
    }
}

impl RemoteClaimResponse {
    pub(crate) fn validate(&self, expected: &RemoteClaimRequest) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        validate_operation_echo(
            &self.binding,
            &self.offer_request_sha256,
            &expected.binding,
            &expected.offer_request_sha256,
        )?;
        self.lease.validate()?;
        require_canonical_time("claimed_at", &self.claimed_at)?;
        require_serialized_size(
            "claim_response",
            self,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )
    }
}

impl RemoteLeaseRenewResponse {
    pub(crate) fn validate(
        &self,
        expected: &RemoteLeaseRenewRequest,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        validate_operation_echo(
            &self.binding,
            &self.offer_request_sha256,
            &expected.binding,
            &expected.offer_request_sha256,
        )?;
        self.lease.validate()?;
        require_serialized_size(
            "lease_renew_response",
            self,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )
    }
}

impl RemoteStatusResponse {
    pub(crate) fn validate(&self, expected: &RemoteStatusRequest) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        self.binding.validate()?;
        require_digest("offer_request_sha256", &self.offer_request_sha256)?;
        if self.binding != expected.binding
            || self.offer_request_sha256 != expected.offer_request_sha256
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        require_canonical_time("observed_at", &self.observed_at)?;
        validate_run_evidence(self)?;
        if let Some(lease) = &self.lease {
            lease.validate()?;
        }
        self.output_artifacts.validate()?;
        if self.state != RemoteAssignmentWireState::Failed && self.failure_class.is_some() {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        match self.state {
            RemoteAssignmentWireState::Completed => {
                if self.error_code.is_some() {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
                self.result
                    .as_ref()
                    .ok_or(RemoteWireError::MissingField("result"))?
                    .validate(&expected.binding, &expected.offer_request_sha256)?;
            }
            RemoteAssignmentWireState::Failed => {
                if self.result.is_some() || !self.output_artifacts.entries.is_empty() {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
                let failure_class = self
                    .failure_class
                    .ok_or(RemoteWireError::MissingField("failure_class"))?;
                if failure_class == crate::task_board::TaskBoardFailureClass::UnknownOutcome {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
                require_text("error_code", self.error_code.as_deref().unwrap_or_default())?;
            }
            RemoteAssignmentWireState::Cancelled
            | RemoteAssignmentWireState::Superseded
            | RemoteAssignmentWireState::Unknown => {
                if self.result.is_some() || !self.output_artifacts.entries.is_empty() {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
            }
            RemoteAssignmentWireState::Offered
            | RemoteAssignmentWireState::Claimed
            | RemoteAssignmentWireState::Running => {
                if self.result.is_some()
                    || self.error_code.is_some()
                    || !self.output_artifacts.entries.is_empty()
                {
                    return Err(RemoteWireError::ResultBindingMismatch);
                }
            }
        }
        validate_status_digest(self)?;
        require_serialized_size(
            "status_response",
            self,
            MAX_REMOTE_LIFECYCLE_JSON_BYTES,
        )
    }

    pub(crate) fn confirms_cancel(&self, expected: &RemoteCancelRequest) -> bool {
        self.schema_version == expected.schema_version
            && self.state == RemoteAssignmentWireState::Cancelled
            && self.binding == expected.binding
            && self.offer_request_sha256 == expected.offer_request_sha256
            && self
                .lease
                .as_ref()
                .is_some_and(|lease| lease.lease_id == expected.lease_id)
            && self.error_code.as_deref() == Some(expected.reason.as_str())
    }
}

impl RemoteCancelResponse {
    pub(crate) fn seal(mut self, expected: &RemoteCancelRequest) -> Result<Self, RemoteWireError> {
        expected.validate()?;
        self.cancel_response_sha256.clear();
        self.cancel_response_sha256 = domain_digest(
            "harness.task-board.remote-cancel-response.v1",
            &(&expected.request_sha256, &self),
        )?;
        Ok(self)
    }

    pub(crate) fn validate(&self, expected: &RemoteCancelRequest) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        validate_operation_echo(
            &self.binding,
            &self.offer_request_sha256,
            &expected.binding,
            &expected.offer_request_sha256,
        )?;
        require_digest("cancel_response_sha256", &self.cancel_response_sha256)?;
        if matches!(
            self.state,
            RemoteAssignmentWireState::Offered
                | RemoteAssignmentWireState::Claimed
                | RemoteAssignmentWireState::Running
                | RemoteAssignmentWireState::Unknown
        ) {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        require_canonical_time("observed_at", &self.observed_at)?;
        validate_cancel_run_evidence(self)?;
        let mut unsigned = self.clone();
        unsigned.cancel_response_sha256.clear();
        let digest = domain_digest(
            "harness.task-board.remote-cancel-response.v1",
            &(&expected.request_sha256, &unsigned),
        )?;
        if digest == self.cancel_response_sha256 {
            require_serialized_size(
                "cancel_response",
                self,
                MAX_REMOTE_RECEIPT_JSON_BYTES,
            )
        } else {
            Err(RemoteWireError::DigestMismatch("cancel_response_sha256"))
        }
    }
}

fn validate_cancel_run_evidence(response: &RemoteCancelResponse) -> Result<(), RemoteWireError> {
    match (
        &response.claimed_at,
        &response.started_at,
        &response.workspace_ref,
    ) {
        (None, None, None) => Ok(()),
        (Some(claimed_at), None, None) => {
            require_canonical_time("claimed_at", claimed_at)?;
            let claimed = chrono::DateTime::parse_from_rfc3339(claimed_at)
                .map_err(|_| RemoteWireError::InvalidTimestamp("claimed_at"))?;
            let observed = chrono::DateTime::parse_from_rfc3339(&response.observed_at)
                .map_err(|_| RemoteWireError::InvalidTimestamp("observed_at"))?;
            if claimed <= observed {
                Ok(())
            } else {
                Err(RemoteWireError::ResultBindingMismatch)
            }
        }
        (Some(claimed_at), Some(started_at), Some(workspace_ref)) => {
            require_canonical_time("claimed_at", claimed_at)?;
            require_canonical_time("started_at", started_at)?;
            if !opaque_workspace_reference(workspace_ref) {
                return Err(RemoteWireError::InvalidWorkspaceReference);
            }
            let claimed = chrono::DateTime::parse_from_rfc3339(claimed_at)
                .map_err(|_| RemoteWireError::InvalidTimestamp("claimed_at"))?;
            let started = chrono::DateTime::parse_from_rfc3339(started_at)
                .map_err(|_| RemoteWireError::InvalidTimestamp("started_at"))?;
            let observed = chrono::DateTime::parse_from_rfc3339(&response.observed_at)
                .map_err(|_| RemoteWireError::InvalidTimestamp("observed_at"))?;
            if claimed <= started && started <= observed {
                Ok(())
            } else {
                Err(RemoteWireError::ResultBindingMismatch)
            }
        }
        _ => Err(RemoteWireError::ResultBindingMismatch),
    }
}

impl RemoteSettledResponse {
    pub(crate) fn validate(&self, expected: &RemoteSettledRequest) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        validate_operation_echo(
            &self.binding,
            &self.offer_request_sha256,
            &expected.binding,
            &expected.offer_request_sha256,
        )?;
        require_digest("settlement_request_sha256", &self.settlement_request_sha256)?;
        if self.settlement_request_sha256 != expected.request_sha256 {
            return Err(RemoteWireError::DigestMismatch("settlement_request_sha256"));
        }
        require_canonical_time("settled_at", &self.settled_at)?;
        require_serialized_size(
            "settled_response",
            self,
            MAX_REMOTE_RECEIPT_JSON_BYTES,
        )
    }
}

impl RemoteArtifactFetchResponse {
    pub(crate) fn validate(
        &self,
        expected: &RemoteArtifactFetchRequest,
    ) -> Result<Vec<u8>, RemoteWireError> {
        require_version(self.schema_version)?;
        self.binding.validate()?;
        require_digest("offer_request_sha256", &self.offer_request_sha256)?;
        if self.binding != expected.binding
            || self.offer_request_sha256 != expected.offer_request_sha256
            || self.artifact.relative_path != expected.relative_path
            || self.artifact.sha256 != expected.expected_sha256
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        RemoteArtifactManifest {
            entries: vec![self.artifact.clone()],
        }
        .validate()?;
        let content = base64::engine::general_purpose::STANDARD
            .decode(&self.content_base64)
            .map_err(|_| RemoteWireError::InvalidManifest)?;
        if content.len() as u64 != self.artifact.size_bytes
            || hex::encode(Sha256::digest(&content)) != self.artifact.sha256
        {
            return Err(RemoteWireError::DigestMismatch("artifact_sha256"));
        }
        Ok(content)
    }
}

fn validate_operation_echo(
    actual_binding: &RemoteAttemptBinding,
    actual_offer_digest: &str,
    expected_binding: &RemoteAttemptBinding,
    expected_offer_digest: &str,
) -> Result<(), RemoteWireError> {
    actual_binding.validate()?;
    require_digest("offer_request_sha256", actual_offer_digest)?;
    if actual_binding != expected_binding || actual_offer_digest != expected_offer_digest {
        return Err(RemoteWireError::ResultBindingMismatch);
    }
    Ok(())
}

fn validate_run_evidence(response: &RemoteStatusResponse) -> Result<(), RemoteWireError> {
    let stage = run_evidence_stage(response)?;
    match (response.state, stage) {
        (RemoteAssignmentWireState::Offered, RunEvidenceStage::Offered)
        | (RemoteAssignmentWireState::Claimed, RunEvidenceStage::Claimed)
        // A Start that failed before attaching a run reports Failed with claim evidence
        // but no start evidence.
        | (RemoteAssignmentWireState::Failed, RunEvidenceStage::Claimed)
        | (
            RemoteAssignmentWireState::Running
            | RemoteAssignmentWireState::Completed
            | RemoteAssignmentWireState::Failed,
            RunEvidenceStage::Started,
        )
        | (
            RemoteAssignmentWireState::Cancelled
            | RemoteAssignmentWireState::Superseded
            | RemoteAssignmentWireState::Unknown,
            _,
        ) => Ok(()),
        _ => Err(RemoteWireError::ResultBindingMismatch),
    }
}

#[derive(Clone, Copy)]
enum RunEvidenceStage {
    Offered,
    Claimed,
    Started,
}

fn run_evidence_stage(
    response: &RemoteStatusResponse,
) -> Result<RunEvidenceStage, RemoteWireError> {
    match (
        &response.claimed_at,
        &response.started_at,
        &response.workspace_ref,
    ) {
        (None, None, None) => Ok(RunEvidenceStage::Offered),
        (Some(claimed_at), None, None) => {
            require_canonical_time("claimed_at", claimed_at)?;
            Ok(RunEvidenceStage::Claimed)
        }
        (Some(claimed_at), Some(started_at), Some(workspace_ref)) => {
            require_canonical_time("claimed_at", claimed_at)?;
            require_canonical_time("started_at", started_at)?;
            if !opaque_workspace_reference(workspace_ref) {
                return Err(RemoteWireError::InvalidWorkspaceReference);
            }
            Ok(RunEvidenceStage::Started)
        }
        _ => Err(RemoteWireError::ResultBindingMismatch),
    }
}

fn opaque_workspace_reference(value: &str) -> bool {
    (1..=256).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
        && !value.contains("..")
}

fn validate_status_digest(response: &RemoteStatusResponse) -> Result<(), RemoteWireError> {
    require_digest("status_sha256", &response.status_sha256)?;
    let mut unsigned = response.clone();
    unsigned.status_sha256.clear();
    let expected = domain_digest("harness.task-board.remote-status.v1", &unsigned)?;
    if response.status_sha256 == expected {
        Ok(())
    } else {
        Err(RemoteWireError::DigestMismatch("status_sha256"))
    }
}
