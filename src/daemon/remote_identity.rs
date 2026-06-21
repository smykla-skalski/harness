use std::error::Error;
use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand_core06::{OsRng, RngCore};
use sha2::{Digest, Sha256};

use super::remote::{RemoteAccessScope, RemoteRole, scopes_for_role};

#[cfg(test)]
#[path = "remote_identity_tests.rs"]
mod tests;

const TOKEN_RANDOM_BYTES: usize = 32;
const TOKEN_HINT_CHARS: usize = 6;
const TOKEN_HASH_PREFIX: &str = "sha256:";
const TOKEN_HASH_HEX_LEN: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteIdentityError {
    EmptyClientId,
    EmptyToken,
    ScopeNotAllowed {
        role: RemoteRole,
        scope: RemoteAccessScope,
    },
}

impl fmt::Display for RemoteIdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyClientId => write!(f, "remote client id is required"),
            Self::EmptyToken => write!(f, "remote client token is required"),
            Self::ScopeNotAllowed { role, scope } => write!(
                f,
                "remote role '{}' cannot request '{}' scope",
                role.as_str(),
                scope.as_str()
            ),
        }
    }
}

impl Error for RemoteIdentityError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteTokenHash {
    storage_value: String,
}

impl RemoteTokenHash {
    #[must_use]
    pub fn from_token(token: &str) -> Self {
        let digest = token_digest(token);
        Self {
            storage_value: format!("{TOKEN_HASH_PREFIX}{}", hex::encode(digest)),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_token_for_tests(token: &str) -> Self {
        Self::from_token(token)
    }

    #[must_use]
    pub fn from_storage_value(value: impl Into<String>) -> Self {
        Self {
            storage_value: value.into(),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_storage_value_for_tests(value: impl Into<String>) -> Self {
        Self::from_storage_value(value)
    }

    #[must_use]
    pub fn as_storage_value(&self) -> &str {
        &self.storage_value
    }

    #[must_use]
    pub fn verify(&self, token: &str) -> bool {
        let Some(expected) = parse_storage_digest(&self.storage_value) else {
            let candidate = token_digest(token);
            let _ = constant_time_eq(&[0_u8; 32], &candidate);
            return false;
        };
        let candidate = token_digest(token);
        constant_time_eq(&expected, &candidate)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteBearerToken {
    value: String,
}

impl RemoteBearerToken {
    #[must_use]
    pub fn generate() -> Self {
        let mut bytes = [0_u8; TOKEN_RANDOM_BYTES];
        OsRng.fill_bytes(&mut bytes);
        Self {
            value: URL_SAFE_NO_PAD.encode(bytes),
        }
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        &self.value
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteClientRegistration {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    pub role: RemoteRole,
    pub scopes: Vec<RemoteAccessScope>,
    pub token_hash: RemoteTokenHash,
    pub token_hint: String,
    pub created_at: String,
}

impl RemoteClientRegistration {
    /// Build a client registration from the server-generated opaque bearer token.
    ///
    /// # Errors
    /// Returns [`RemoteIdentityError`] when the client id/token is blank or a
    /// requested scope is not allowed by the role.
    pub fn new(
        client_id: impl Into<String>,
        display_name: impl Into<String>,
        platform: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        token: &str,
        created_at: impl Into<String>,
    ) -> Result<Self, RemoteIdentityError> {
        let client_id = client_id.into();
        if client_id.trim().is_empty() {
            return Err(RemoteIdentityError::EmptyClientId);
        }
        if token.trim().is_empty() {
            return Err(RemoteIdentityError::EmptyToken);
        }
        Ok(Self {
            client_id,
            display_name: display_name.into(),
            platform: platform.into(),
            role,
            scopes: expand_client_scopes(role, requested_scopes)?,
            token_hash: RemoteTokenHash::from_token(token),
            token_hint: token_hint(token),
            created_at: created_at.into(),
        })
    }

    #[cfg(test)]
    pub fn new_for_tests(
        client_id: impl Into<String>,
        display_name: impl Into<String>,
        platform: impl Into<String>,
        role: RemoteRole,
        requested_scopes: &[RemoteAccessScope],
        token: &str,
        created_at: impl Into<String>,
    ) -> Result<Self, RemoteIdentityError> {
        Self::new(
            client_id,
            display_name,
            platform,
            role,
            requested_scopes,
            token,
            created_at,
        )
    }

    #[must_use]
    pub fn scopes(&self) -> &[RemoteAccessScope] {
        &self.scopes
    }

    #[must_use]
    pub fn token_hint(&self) -> &str {
        &self.token_hint
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteStoredClient {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    pub role: RemoteRole,
    pub scopes: Vec<RemoteAccessScope>,
    pub token_hash: RemoteTokenHash,
    pub token_hint: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub rotated_at: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAuditScopeDecision {
    Allowed,
    Denied,
}

impl RemoteAuditScopeDecision {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Allowed => "allowed",
            Self::Denied => "denied",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAuditOutcome {
    Success,
    Failure,
}

impl RemoteAuditOutcome {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Failure => "failure",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteAuditEvent {
    pub event_id: String,
    pub recorded_at: String,
    pub request_id: Option<String>,
    pub client_id: Option<String>,
    pub route_or_method: String,
    pub scope: RemoteAccessScope,
    pub scope_decision: RemoteAuditScopeDecision,
    pub outcome: RemoteAuditOutcome,
    pub remote_addr: Option<String>,
    pub error_detail: Option<String>,
}

impl RemoteAuditEvent {
    #[must_use]
    #[expect(
        clippy::too_many_arguments,
        reason = "audit records are flat wire rows and tests need explicit field values"
    )]
    pub fn new(
        event_id: impl Into<String>,
        recorded_at: impl Into<String>,
        request_id: Option<&str>,
        client_id: Option<&str>,
        route_or_method: impl Into<String>,
        scope: RemoteAccessScope,
        scope_decision: RemoteAuditScopeDecision,
        outcome: RemoteAuditOutcome,
        remote_addr: Option<&str>,
        error_detail: Option<&str>,
    ) -> Self {
        Self {
            event_id: event_id.into(),
            recorded_at: recorded_at.into(),
            request_id: request_id.map(ToOwned::to_owned),
            client_id: client_id.map(ToOwned::to_owned),
            route_or_method: route_or_method.into(),
            scope,
            scope_decision,
            outcome,
            remote_addr: remote_addr.map(ToOwned::to_owned),
            error_detail: error_detail.map(redact_remote_error_detail),
        }
    }

    #[must_use]
    pub fn error_detail(&self) -> Option<&str> {
        self.error_detail.as_deref()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteStoredAuditEvent {
    pub event_id: String,
    pub recorded_at: String,
    pub request_id: Option<String>,
    pub client_id: Option<String>,
    pub route_or_method: String,
    pub scope: RemoteAccessScope,
    pub scope_decision: RemoteAuditScopeDecision,
    pub outcome: RemoteAuditOutcome,
    pub remote_addr: Option<String>,
    pub error_detail: Option<String>,
}

/// Expand the role default scopes, optionally narrowed by the requested scopes.
///
/// # Errors
/// Returns [`RemoteIdentityError::ScopeNotAllowed`] when a requested scope is
/// outside the selected role.
pub fn expand_client_scopes(
    role: RemoteRole,
    requested_scopes: &[RemoteAccessScope],
) -> Result<Vec<RemoteAccessScope>, RemoteIdentityError> {
    let allowed = scopes_for_role(role);
    if requested_scopes.is_empty() {
        return Ok(allowed.to_vec());
    }
    for scope in requested_scopes {
        if !allowed.contains(scope) {
            return Err(RemoteIdentityError::ScopeNotAllowed {
                role,
                scope: *scope,
            });
        }
    }
    let mut scopes = Vec::new();
    for scope in requested_scopes {
        if !scopes.contains(scope) {
            scopes.push(*scope);
        }
    }
    Ok(scopes)
}

#[must_use]
pub fn parse_remote_scope(value: &str) -> Option<RemoteAccessScope> {
    match value {
        "read" => Some(RemoteAccessScope::Read),
        "write" => Some(RemoteAccessScope::Write),
        "admin" => Some(RemoteAccessScope::Admin),
        _ => None,
    }
}

#[must_use]
pub fn parse_remote_role(value: &str) -> Option<RemoteRole> {
    match value {
        "admin" => Some(RemoteRole::Admin),
        "operator" => Some(RemoteRole::Operator),
        "viewer" => Some(RemoteRole::Viewer),
        _ => None,
    }
}

fn token_digest(token: &str) -> [u8; 32] {
    Sha256::digest(token.as_bytes()).into()
}

fn parse_storage_digest(value: &str) -> Option<[u8; 32]> {
    let hex_value = value.strip_prefix(TOKEN_HASH_PREFIX)?;
    if hex_value.len() != TOKEN_HASH_HEX_LEN {
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

fn token_hint(token: &str) -> String {
    let chars = token.chars().collect::<Vec<_>>();
    chars
        .iter()
        .skip(chars.len().saturating_sub(TOKEN_HINT_CHARS))
        .copied()
        .collect()
}

fn redact_remote_error_detail(detail: &str) -> String {
    let mut redacted = String::with_capacity(detail.len());
    let mut offset = 0;

    while offset < detail.len() {
        let rest = &detail[offset..];
        if let Some(key) = ["secret=", "token=", "authorization="]
            .into_iter()
            .find(|key| rest.starts_with(key))
        {
            redacted.push_str(key);
            redacted.push_str("<redacted>");
            offset += key.len();
            while let Some(value_char) = detail[offset..].chars().next() {
                if is_secret_value_terminator(value_char) {
                    break;
                }
                offset += value_char.len_utf8();
            }
        } else if let Some(plain_char) = rest.chars().next() {
            redacted.push(plain_char);
            offset += plain_char.len_utf8();
        }
    }

    redacted
}

fn is_secret_value_terminator(value_char: char) -> bool {
    value_char.is_whitespace()
        || matches!(value_char, '&' | ';' | ',' | ')' | ']' | '}' | '"' | '\'')
}
