use std::error::Error;
use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand_core06::{OsRng, RngCore};
use serde::Serialize;

use super::remote::{RemoteAccessScope, RemoteRole, scopes_for_role};
use super::remote_crypto::{
    parse_sha256_storage_digest, sha256_storage_value, verify_sha256_storage_value,
};

#[cfg(test)]
#[path = "remote_identity_tests.rs"]
mod tests;

const TOKEN_RANDOM_BYTES: usize = 32;
const TOKEN_HINT_CHARS: usize = 6;
const REDACTED_TOKEN_HINT: &str = "<redacted>";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteIdentityError {
    EmptyClientId,
    EmptyToken,
    InvalidStoredTokenHash,
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
            Self::InvalidStoredTokenHash => write!(f, "remote client token hash is invalid"),
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
        Self {
            storage_value: sha256_storage_value(token),
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_token_for_tests(token: &str) -> Self {
        Self::from_token(token)
    }

    /// Build a hash wrapper from persisted storage after validating its format.
    ///
    /// # Errors
    /// Returns [`RemoteIdentityError::InvalidStoredTokenHash`] when the value is
    /// not a `sha256:`-prefixed 32-byte digest encoded as 64 hex characters.
    pub(crate) fn try_from_storage_value(
        value: impl Into<String>,
    ) -> Result<Self, RemoteIdentityError> {
        let storage_value = value.into();
        if parse_sha256_storage_digest(&storage_value).is_none() {
            return Err(RemoteIdentityError::InvalidStoredTokenHash);
        }
        Ok(Self { storage_value })
    }

    #[cfg(test)]
    pub fn try_from_storage_value_for_tests(
        value: impl Into<String>,
    ) -> Result<Self, RemoteIdentityError> {
        Self::try_from_storage_value(value)
    }

    #[must_use]
    pub fn as_storage_value(&self) -> &str {
        &self.storage_value
    }

    #[must_use]
    pub fn verify(&self, token: &str) -> bool {
        verify_sha256_storage_value(&self.storage_value, token)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct RemoteBearerToken {
    value: String,
}

impl fmt::Debug for RemoteBearerToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteBearerToken")
            .field("value", &"<redacted>")
            .finish()
    }
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
            token_hint: remote_token_hint(token),
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

#[derive(Serialize)]
struct RemoteControlPlaneActor<'a> {
    client_id: &'a str,
    platform: &'a str,
    role: &'static str,
    scopes: Vec<&'static str>,
}

impl RemoteStoredClient {
    #[must_use]
    /// Serialize the authenticated, token-free actor identity for mutation attribution.
    ///
    /// # Panics
    /// Panics only if `serde_json` cannot serialize the string-only identity fields.
    pub fn control_plane_actor_id(&self) -> String {
        let actor = RemoteControlPlaneActor {
            client_id: &self.client_id,
            platform: &self.platform,
            role: self.role.as_str(),
            scopes: self.scopes.iter().map(|scope| scope.as_str()).collect(),
        };
        serde_json::to_string(&actor).expect("remote control-plane actor serialization")
    }
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

pub(crate) fn remote_token_hint(token: &str) -> String {
    let chars = token.chars().collect::<Vec<_>>();
    if chars.len() <= TOKEN_HINT_CHARS {
        return REDACTED_TOKEN_HINT.to_owned();
    }
    chars
        .iter()
        .skip(chars.len().saturating_sub(TOKEN_HINT_CHARS))
        .copied()
        .collect()
}

pub(crate) fn redact_remote_error_detail(detail: &str) -> String {
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
