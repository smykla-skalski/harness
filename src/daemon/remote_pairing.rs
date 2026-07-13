use std::error::Error;
use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand_core06::{OsRng, RngCore};

use super::remote::{RemoteAccessScope, RemoteRole};
use super::remote_crypto::{
    parse_sha256_storage_digest, sha256_storage_value, verify_sha256_storage_value,
};
use super::remote_identity::{RemoteBearerToken, RemoteIdentityError, RemoteStoredClient};
use crate::reviews::ReviewsQueryRequest;

mod reviews;
pub(crate) use reviews::normalize_remote_reviews_query;
mod rate_limit;
pub use rate_limit::RemotePairingRateLimiter;

#[cfg(test)]
#[path = "remote_pairing_tests.rs"]
mod tests;

const PAIRING_RANDOM_BYTES: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemotePairingError {
    EmptyPairingId,
    EmptyCode,
    EmptyClientId,
    EmptyDomain,
    EmptyDisplayName,
    EmptyPlatform,
    EmptyAuditEventId,
    InvalidStoredCodeHash,
    WrongDomain { expected: String, actual: String },
    RateLimited,
    Expired,
    AlreadyClaimed,
    UnknownCode,
    InvalidReviewsQuery(String),
    Identity(RemoteIdentityError),
}

impl fmt::Display for RemotePairingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyPairingId => write!(f, "remote pairing id is required"),
            Self::EmptyCode => write!(f, "remote pairing code is required"),
            Self::EmptyClientId => write!(f, "remote pairing client id is required"),
            Self::EmptyDomain => write!(f, "remote pairing domain is required"),
            Self::EmptyDisplayName => write!(f, "remote pairing display name is required"),
            Self::EmptyPlatform => write!(f, "remote pairing platform is required"),
            Self::EmptyAuditEventId => write!(f, "remote pairing audit event id is required"),
            Self::InvalidStoredCodeHash => write!(f, "remote pairing code hash is invalid"),
            Self::WrongDomain { expected, actual } => write!(
                f,
                "wrong remote pairing domain: expected '{expected}', got '{actual}'"
            ),
            Self::RateLimited => write!(f, "remote pairing attempts are rate limited"),
            Self::Expired => write!(f, "remote pairing code expired"),
            Self::AlreadyClaimed => write!(f, "remote pairing code already claimed"),
            Self::UnknownCode => write!(f, "remote pairing code is unknown"),
            Self::InvalidReviewsQuery(detail) => {
                write!(f, "remote pairing reviews query is invalid: {detail}")
            }
            Self::Identity(error) => write!(f, "{error}"),
        }
    }
}

impl Error for RemotePairingError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Identity(error) => Some(error),
            Self::EmptyPairingId
            | Self::EmptyCode
            | Self::EmptyClientId
            | Self::EmptyDomain
            | Self::EmptyDisplayName
            | Self::EmptyPlatform
            | Self::EmptyAuditEventId
            | Self::InvalidStoredCodeHash
            | Self::WrongDomain { .. }
            | Self::RateLimited
            | Self::Expired
            | Self::AlreadyClaimed
            | Self::UnknownCode
            | Self::InvalidReviewsQuery(_) => None,
        }
    }
}

impl From<RemoteIdentityError> for RemotePairingError {
    fn from(error: RemoteIdentityError) -> Self {
        Self::Identity(error)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct RemotePairingCode {
    value: String,
}

impl fmt::Debug for RemotePairingCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemotePairingCode")
            .field("value", &"<redacted>")
            .finish()
    }
}

impl RemotePairingCode {
    #[must_use]
    pub fn generate() -> Self {
        let mut bytes = [0_u8; PAIRING_RANDOM_BYTES];
        OsRng.fill_bytes(&mut bytes);
        Self {
            value: URL_SAFE_NO_PAD.encode(bytes),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_value_for_tests(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
        }
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        &self.value
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePairingCodeHash {
    storage_value: String,
}

impl RemotePairingCodeHash {
    /// Build a pairing code hash from the one-time pairing code.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::EmptyCode`] when the pairing code is blank.
    pub fn from_code(code: &str) -> Result<Self, RemotePairingError> {
        let code = code.trim();
        if code.is_empty() {
            return Err(RemotePairingError::EmptyCode);
        }
        Ok(Self {
            storage_value: sha256_storage_value(code),
        })
    }

    /// Build a pairing hash wrapper from persisted storage after validation.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::InvalidStoredCodeHash`] when the value is
    /// not a `sha256:`-prefixed 32-byte digest encoded as 64 hex characters.
    pub(crate) fn try_from_storage_value(
        value: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        let storage_value = value.into();
        if parse_sha256_storage_digest(&storage_value).is_none() {
            return Err(RemotePairingError::InvalidStoredCodeHash);
        }
        Ok(Self { storage_value })
    }

    #[must_use]
    pub fn as_storage_value(&self) -> &str {
        &self.storage_value
    }

    #[must_use]
    pub fn verify(&self, code: &str) -> bool {
        verify_sha256_storage_value(&self.storage_value, code.trim())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePairingRecord {
    pub pairing_id: String,
    pub code_hash: RemotePairingCodeHash,
    pub role: RemoteRole,
    pub scopes: Vec<RemoteAccessScope>,
    pub created_at: String,
    pub expires_at: String,
    pub reviews_query: Option<ReviewsQueryRequest>,
}

impl RemotePairingRecord {
    /// Build a durable one-time pairing record without retaining the raw code.
    ///
    /// # Errors
    /// Returns [`RemotePairingError`] for blank ids/codes and requested scopes
    /// that exceed the selected role.
    pub fn new(
        pairing_id: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        code: &str,
        created_at: impl Into<String>,
        expires_at: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        Self::new_with_reviews_query(
            pairing_id,
            role,
            requested_scopes,
            code,
            created_at,
            expires_at,
            None,
        )
    }

    #[cfg(test)]
    pub fn new_for_tests(
        pairing_id: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        code: &str,
        created_at: impl Into<String>,
        expires_at: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        Self::new(
            pairing_id,
            role,
            requested_scopes,
            code,
            created_at,
            expires_at,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteStoredPairing {
    pub pairing_id: String,
    pub code_hash: RemotePairingCodeHash,
    pub role: RemoteRole,
    pub scopes: Vec<RemoteAccessScope>,
    pub created_at: String,
    pub expires_at: String,
    pub claimed_at: Option<String>,
    pub claimed_client_id: Option<String>,
    pub claim_remote_addr: Option<String>,
    pub reviews_query: Option<ReviewsQueryRequest>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemotePairingStatus {
    Pending,
    Claimed,
    Expired,
    Unavailable,
}

impl RemotePairingStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Claimed => "claimed",
            Self::Expired => "expired",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePairingClaimRequest {
    pub expected_domain: String,
    pub claimed_domain: String,
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    pub remote_addr: Option<String>,
    pub audit_event_id: String,
}

impl RemotePairingClaimRequest {
    /// Build a pairing claim request.
    ///
    /// `expected_domain` must come from daemon-side remote configuration.
    /// `claimed_domain` is the domain sent by the public claim endpoint.
    ///
    /// # Errors
    /// Returns [`RemotePairingError`] when the domains, client id, display name,
    /// platform, or audit event id are blank.
    pub fn new(
        expected_domain: impl Into<String>,
        claimed_domain: impl Into<String>,
        client_id: impl Into<String>,
        display_name: impl Into<String>,
        platform: impl Into<String>,
        remote_addr: Option<&str>,
        audit_event_id: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        let expected_domain = expected_domain.into();
        let claimed_domain = claimed_domain.into();
        let client_id = client_id.into();
        let display_name = display_name.into();
        let platform = platform.into();
        let audit_event_id = audit_event_id.into();
        if expected_domain.trim().is_empty() || claimed_domain.trim().is_empty() {
            return Err(RemotePairingError::EmptyDomain);
        }
        if client_id.trim().is_empty() {
            return Err(RemotePairingError::EmptyClientId);
        }
        if display_name.trim().is_empty() {
            return Err(RemotePairingError::EmptyDisplayName);
        }
        if platform.trim().is_empty() {
            return Err(RemotePairingError::EmptyPlatform);
        }
        validate_pairing_audit_event_id(&audit_event_id)?;
        Ok(Self {
            expected_domain,
            claimed_domain,
            client_id,
            display_name,
            platform,
            remote_addr: remote_addr.map(ToOwned::to_owned),
            audit_event_id,
        })
    }

    #[cfg(test)]
    pub fn new_for_tests(
        expected_domain: impl Into<String>,
        claimed_domain: impl Into<String>,
        client_id: impl Into<String>,
        display_name: impl Into<String>,
        platform: impl Into<String>,
        remote_addr: Option<&str>,
        audit_event_id: impl Into<String>,
    ) -> Result<Self, RemotePairingError> {
        Self::new(
            expected_domain,
            claimed_domain,
            client_id,
            display_name,
            platform,
            remote_addr,
            audit_event_id,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePairingClaimedClient {
    pub client: RemoteStoredClient,
    pub bearer_token: RemoteBearerToken,
    pub reviews_query: Option<ReviewsQueryRequest>,
}

/// Validate that the public claim domain matches the daemon endpoint domain.
///
/// # Errors
/// Returns [`RemotePairingError`] when either domain is blank or they differ.
pub fn validate_pairing_domain(expected: &str, actual: &str) -> Result<(), RemotePairingError> {
    let expected = expected.trim();
    let actual = actual.trim();
    if expected.is_empty() || actual.is_empty() {
        return Err(RemotePairingError::EmptyDomain);
    }
    if !expected.eq_ignore_ascii_case(actual) {
        return Err(RemotePairingError::WrongDomain {
            expected: expected.to_string(),
            actual: actual.to_string(),
        });
    }
    Ok(())
}

/// Validate the audit event id used by remote pairing persistence.
///
/// # Errors
/// Returns [`RemotePairingError::EmptyAuditEventId`] when the id is blank.
pub fn validate_pairing_audit_event_id(value: &str) -> Result<(), RemotePairingError> {
    if value.trim().is_empty() {
        return Err(RemotePairingError::EmptyAuditEventId);
    }
    Ok(())
}
