use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use rand_core06::{OsRng, RngCore};
use sha2::{Digest, Sha256};

use super::remote::{RemoteAccessScope, RemoteRole};
use super::remote_identity::{
    expand_client_scopes, RemoteBearerToken, RemoteIdentityError, RemoteStoredClient,
};

#[cfg(test)]
#[path = "remote_pairing_tests.rs"]
mod tests;

const PAIRING_RANDOM_BYTES: usize = 32;
const PAIRING_HASH_PREFIX: &str = "sha256:";
const PAIRING_HASH_HEX_LEN: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemotePairingError {
    EmptyPairingId,
    EmptyCode,
    EmptyClientId,
    EmptyDomain,
    EmptyDisplayName,
    EmptyPlatform,
    InvalidStoredCodeHash,
    WrongDomain { expected: String, actual: String },
    RateLimited,
    Expired,
    AlreadyClaimed,
    UnknownCode,
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
            Self::InvalidStoredCodeHash => write!(f, "remote pairing code hash is invalid"),
            Self::WrongDomain { expected, actual } => write!(
                f,
                "wrong remote pairing domain: expected '{expected}', got '{actual}'"
            ),
            Self::RateLimited => write!(f, "remote pairing attempts are rate limited"),
            Self::Expired => write!(f, "remote pairing code expired"),
            Self::AlreadyClaimed => write!(f, "remote pairing code already claimed"),
            Self::UnknownCode => write!(f, "remote pairing code is unknown"),
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
            | Self::InvalidStoredCodeHash
            | Self::WrongDomain { .. }
            | Self::RateLimited
            | Self::Expired
            | Self::AlreadyClaimed
            | Self::UnknownCode => None,
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
        if code.trim().is_empty() {
            return Err(RemotePairingError::EmptyCode);
        }
        let digest = pairing_digest(code);
        Ok(Self {
            storage_value: format!("{PAIRING_HASH_PREFIX}{}", hex::encode(digest)),
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
        if parse_pairing_storage_digest(&storage_value).is_none() {
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
        let Some(expected) = parse_pairing_storage_digest(&self.storage_value) else {
            let candidate = pairing_digest(code);
            let _ = constant_time_eq(&[0_u8; 32], &candidate);
            return false;
        };
        let candidate = pairing_digest(code);
        constant_time_eq(&expected, &candidate)
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
        let pairing_id = pairing_id.into();
        if pairing_id.trim().is_empty() {
            return Err(RemotePairingError::EmptyPairingId);
        }
        Ok(Self {
            pairing_id,
            code_hash: RemotePairingCodeHash::from_code(code)?,
            role,
            scopes: expand_client_scopes(role, requested_scopes)?,
            created_at: created_at.into(),
            expires_at: expires_at.into(),
        })
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
    /// Build a pairing claim request from public claim endpoint fields.
    ///
    /// # Errors
    /// Returns [`RemotePairingError`] when the domains, client id, display name,
    /// or platform are blank.
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
        Ok(Self {
            expected_domain,
            claimed_domain,
            client_id,
            display_name,
            platform,
            remote_addr: remote_addr.map(ToOwned::to_owned),
            audit_event_id: audit_event_id.into(),
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
}

#[derive(Debug, Clone)]
pub struct RemotePairingRateLimiter {
    max_attempts: u32,
    attempts: BTreeMap<String, u32>,
}

impl RemotePairingRateLimiter {
    #[must_use]
    pub fn new(max_attempts: u32) -> Self {
        Self {
            max_attempts: max_attempts.max(1),
            attempts: BTreeMap::new(),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn new_for_tests(max_attempts: u32) -> Self {
        Self::new(max_attempts)
    }

    /// Record one failed/suspicious pairing attempt for an address/code tuple.
    ///
    /// # Errors
    /// Returns [`RemotePairingError::RateLimited`] after the configured limit.
    pub fn record_attempt(
        &mut self,
        remote_addr: &str,
        code_fingerprint: &str,
    ) -> Result<(), RemotePairingError> {
        let key = format!("{remote_addr}\0{code_fingerprint}");
        let count = self.attempts.entry(key).or_insert(0);
        if *count >= self.max_attempts {
            return Err(RemotePairingError::RateLimited);
        }
        *count += 1;
        Ok(())
    }
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

fn pairing_digest(code: &str) -> [u8; 32] {
    Sha256::digest(code.as_bytes()).into()
}

fn parse_pairing_storage_digest(value: &str) -> Option<[u8; 32]> {
    let hex_value = value.strip_prefix(PAIRING_HASH_PREFIX)?;
    if hex_value.len() != PAIRING_HASH_HEX_LEN {
        return None;
    }
    let mut digest = [0_u8; 32];
    hex::decode_to_slice(hex_value, &mut digest).ok()?;
    Some(digest)
}

fn constant_time_eq(left: &[u8; 32], right: &[u8; 32]) -> bool {
    let diff = left
        .iter()
        .zip(right.iter())
        .fold(0_u8, |acc, (&left, &right)| acc | (left ^ right));
    diff == 0
}
