use std::error::Error;
use std::fmt;

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    TaskBoardExecutionPhase, TaskBoardFailureClass, TaskBoardWorkflowKind,
    normalize_repository_slug,
};

#[cfg(test)]
pub use super::wire_artifacts::MAX_REMOTE_ARTIFACT_BYTES;
pub(super) use super::wire_artifacts::valid_artifact_path;
pub use super::wire_artifacts::{RemoteArtifactEntry, RemoteArtifactManifest};

pub use super::wire_host::RemoteHostAdvertisement;
pub use super::wire_launch::RemoteRuntimeLaunchEnvelope;
// `harness-daemon`'s own `db` and `service` tests build this crate as an
// ordinary dependency, so a bare `cfg(test)` (scoped to this crate's own
// test binary) would hide these from them; `test-support` is this crate's
// established way to expose a test-only item across that crate boundary.
#[cfg(any(test, feature = "test-support"))]
pub use super::wire_launch::test_codex_launch;
pub use super::wire_lifecycle::{
    RemoteArtifactFetchRequest, RemoteArtifactFetchResponse, RemoteCancelRequest,
    RemoteCancelResponse, RemoteSettledRequest, RemoteSettledResponse,
};
#[cfg(any(test, feature = "test-support"))]
pub use super::wire_result::MAX_REMOTE_TYPED_RESULT_BYTES;
pub use super::wire_result::RemoteTypedResult;
pub use super::wire_source::{RemoteRepositorySelector, RemoteSourceMaterial};
pub use super::wire_source_bundle::{
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
};
pub use super::wire_source_bundle_recovery::{
    RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse,
};

pub const TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteWireError {
    UnsupportedVersion,
    MissingField(&'static str),
    InvalidDigest(&'static str),
    InvalidPhase,
    InvalidWorkflowKind,
    InvalidAttempt,
    InvalidFence,
    InvalidTimestamp(&'static str),
    InvalidWorkspaceReference,
    InvalidCapacity,
    InvalidManifest,
    InvalidSourceMaterial,
    InvalidToken(&'static str),
    DigestMismatch(&'static str),
    ResultBindingMismatch,
    ResultTooLarge,
    EnvelopeTooLarge(&'static str),
    Serialization,
}

impl fmt::Display for RemoteWireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedVersion => write!(formatter, "unsupported remote wire version"),
            Self::MissingField(field) => {
                write!(formatter, "remote wire field '{field}' is required")
            }
            Self::InvalidDigest(field) => {
                write!(formatter, "remote wire digest '{field}' is invalid")
            }
            Self::InvalidPhase => write!(formatter, "remote execution phase is not dispatchable"),
            Self::InvalidWorkflowKind => write!(formatter, "remote workflow kind is invalid"),
            Self::InvalidAttempt => write!(formatter, "remote attempt must be non-zero"),
            Self::InvalidFence => write!(formatter, "remote fencing epoch must be non-zero"),
            Self::InvalidTimestamp(field) => {
                write!(
                    formatter,
                    "remote wire timestamp '{field}' is not canonical"
                )
            }
            Self::InvalidWorkspaceReference => {
                write!(formatter, "remote workspace reference is not opaque")
            }
            Self::InvalidCapacity => write!(formatter, "remote host capacity is invalid"),
            Self::InvalidManifest => write!(formatter, "remote artifact manifest is invalid"),
            Self::InvalidSourceMaterial => write!(formatter, "remote source material is invalid"),
            Self::InvalidToken(field) => {
                write!(formatter, "remote wire token '{field}' is invalid")
            }
            Self::DigestMismatch(field) => {
                write!(formatter, "remote wire digest '{field}' mismatched")
            }
            Self::ResultBindingMismatch => write!(formatter, "remote result binding mismatched"),
            Self::ResultTooLarge => write!(formatter, "remote typed result exceeds its size limit"),
            Self::EnvelopeTooLarge(field) => {
                write!(
                    formatter,
                    "remote wire envelope '{field}' exceeds its size limit"
                )
            }
            Self::Serialization => write!(formatter, "remote wire serialization failed"),
        }
    }
}

impl Error for RemoteWireError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteAttemptBinding {
    pub assignment_id: String,
    pub execution_id: String,
    pub phase: TaskBoardExecutionPhase,
    pub workflow_kind: TaskBoardWorkflowKind,
    pub action_key: String,
    pub attempt: u32,
    pub idempotency_key: String,
    pub host_id: String,
    pub host_instance_id: String,
    pub fencing_epoch: u64,
    pub configuration_revision: u64,
    pub execution_record_sha256: String,
    pub repository: String,
    pub base_revision: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_head_revision: Option<String>,
}

impl RemoteAttemptBinding {
    /// # Errors
    /// Returns [`RemoteWireError`] if a required field is missing,
    /// oversized, or not canonically formatted, or if the phase, workflow
    /// kind, repository, or revision are invalid.
    pub fn validate(&self) -> Result<(), RemoteWireError> {
        for (name, value) in [
            ("assignment_id", self.assignment_id.as_str()),
            ("execution_id", self.execution_id.as_str()),
            ("action_key", self.action_key.as_str()),
            ("idempotency_key", self.idempotency_key.as_str()),
            ("host_id", self.host_id.as_str()),
            ("host_instance_id", self.host_instance_id.as_str()),
            ("repository", self.repository.as_str()),
            ("base_revision", self.base_revision.as_str()),
        ] {
            require_text(name, value)?;
        }
        for (name, value) in [
            ("assignment_id", self.assignment_id.as_str()),
            ("execution_id", self.execution_id.as_str()),
            ("action_key", self.action_key.as_str()),
            ("idempotency_key", self.idempotency_key.as_str()),
            ("host_id", self.host_id.as_str()),
            ("host_instance_id", self.host_instance_id.as_str()),
        ] {
            require_canonical_identity(name, value, 256)?;
        }
        require_max_bytes("repository", &self.repository, 2_048)?;
        if self.attempt == 0 {
            return Err(RemoteWireError::InvalidAttempt);
        }
        if self.fencing_epoch == 0 {
            return Err(RemoteWireError::InvalidFence);
        }
        if !matches!(
            self.phase,
            TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Evaluate
        ) {
            return Err(RemoteWireError::InvalidPhase);
        }
        if matches!(self.workflow_kind, TaskBoardWorkflowKind::Unknown) {
            return Err(RemoteWireError::InvalidWorkflowKind);
        }
        require_digest("execution_record_sha256", &self.execution_record_sha256)?;
        if !valid_repository_slug(&self.repository) || !valid_revision(&self.base_revision) {
            return Err(RemoteWireError::InvalidSourceMaterial);
        }
        if let Some(head) = &self.expected_head_revision
            && !valid_revision(head)
        {
            return Err(RemoteWireError::InvalidSourceMaterial);
        }
        Ok(())
    }
}

pub(super) fn valid_repository_slug(value: &str) -> bool {
    normalize_repository_slug(Some(value)).as_deref() == Some(value)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-'))
}

fn valid_revision(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteOfferRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_seconds: u32,
    pub deadline_at: String,
    pub launch: RemoteRuntimeLaunchEnvelope,
    pub source: RemoteSourceMaterial,
    pub artifacts: RemoteArtifactManifest,
    pub request_sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum RemoteOfferDisposition {
    Accepted,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteLease {
    pub lease_id: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteOfferResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub disposition: RemoteOfferDisposition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease: Option<RemoteLease>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection_code: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteClaimRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteClaimResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub lease: RemoteLease,
    pub claimed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteLeaseRenewRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub extend_seconds: u32,
    pub request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteLeaseRenewResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub lease: RemoteLease,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteStatusRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub request_sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum RemoteAssignmentWireState {
    Offered,
    Claimed,
    Running,
    Completed,
    Failed,
    Cancelled,
    Superseded,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteStatusResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub state: RemoteAssignmentWireState,
    pub offer_request_sha256: String,
    pub status_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease: Option<RemoteLease>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<RemoteTypedResult>,
    pub output_artifacts: RemoteArtifactManifest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_class: Option<TaskBoardFailureClass>,
    pub observed_at: String,
}

impl RemoteStatusResponse {
    /// # Errors
    /// Returns [`RemoteWireError::Serialization`] if the response cannot be
    /// digested.
    pub fn seal(mut self) -> Result<Self, RemoteWireError> {
        self.status_sha256.clear();
        self.status_sha256 = domain_digest("harness.task-board.remote-status.v1", &self)?;
        Ok(self)
    }
}

pub(super) fn domain_digest<T: Serialize>(
    domain: &str,
    value: &T,
) -> Result<String, RemoteWireError> {
    let encoded =
        serde_json::to_vec(&(domain, value)).map_err(|_| RemoteWireError::Serialization)?;
    Ok(hex::encode(Sha256::digest(encoded)))
}

pub(super) fn require_version(version: u32) -> Result<(), RemoteWireError> {
    if version == TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION {
        Ok(())
    } else {
        Err(RemoteWireError::UnsupportedVersion)
    }
}

pub(super) fn require_text(name: &'static str, value: &str) -> Result<(), RemoteWireError> {
    if value.trim().is_empty() {
        Err(RemoteWireError::MissingField(name))
    } else {
        Ok(())
    }
}

pub(super) fn require_max_bytes(
    name: &'static str,
    value: &str,
    max_bytes: usize,
) -> Result<(), RemoteWireError> {
    if value.len() <= max_bytes {
        Ok(())
    } else {
        Err(RemoteWireError::EnvelopeTooLarge(name))
    }
}

pub(super) fn require_canonical_identity(
    name: &'static str,
    value: &str,
    max_bytes: usize,
) -> Result<(), RemoteWireError> {
    require_text(name, value)?;
    require_max_bytes(name, value, max_bytes)?;
    if value
        .bytes()
        .all(|byte| (0x21..=0x7e).contains(&byte) && !matches!(byte, b'"' | b'\\'))
    {
        Ok(())
    } else {
        Err(RemoteWireError::InvalidToken(name))
    }
}

pub(super) fn require_digest(name: &'static str, value: &str) -> Result<(), RemoteWireError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(RemoteWireError::InvalidDigest(name))
    }
}

pub(super) fn require_canonical_time(
    name: &'static str,
    value: &str,
) -> Result<(), RemoteWireError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map(DateTime::<Utc>::from)
        .map_err(|_| RemoteWireError::InvalidTimestamp(name))?;
    if parsed.to_rfc3339_opts(SecondsFormat::AutoSi, true) == value {
        Ok(())
    } else {
        Err(RemoteWireError::InvalidTimestamp(name))
    }
}
