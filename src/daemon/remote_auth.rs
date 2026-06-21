use std::{error::Error, fmt};

use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};

use super::protocol::{HttpApiRouteContract, http_paths};
use super::remote::{RemoteAccessScope, remote_http_scopes, remote_ws_scopes};
use super::remote_identity::RemoteStoredClient;

#[cfg(test)]
#[path = "remote_auth_tests.rs"]
mod tests;

pub const REMOTE_CLIENT_ID_HEADER: &str = "x-harness-remote-client-id";

#[derive(Clone, PartialEq, Eq)]
pub struct RemoteBearerCredentials {
    client_id: String,
    token: String,
}

impl fmt::Debug for RemoteBearerCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteBearerCredentials")
            .field("client_id", &self.client_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

impl RemoteBearerCredentials {
    /// Parse remote bearer credentials from HTTP or WebSocket handshake headers.
    ///
    /// # Errors
    /// Returns [`RemoteAuthError`] when the remote client id or bearer token is
    /// absent or blank.
    pub fn from_headers(headers: &HeaderMap) -> Result<Self, RemoteAuthError> {
        let client_id = headers
            .get(REMOTE_CLIENT_ID_HEADER)
            .and_then(|value| value.to_str().ok())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or(RemoteAuthError::MissingClientId)?;
        let authorization = headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or(RemoteAuthError::MissingBearerToken)?;
        let (scheme, token) = authorization
            .split_once(char::is_whitespace)
            .ok_or(RemoteAuthError::InvalidBearerToken)?;
        if !scheme.eq_ignore_ascii_case("Bearer") {
            return Err(RemoteAuthError::InvalidBearerToken);
        }
        let token = token.trim();
        if token.is_empty() {
            return Err(RemoteAuthError::InvalidBearerToken);
        }
        Ok(Self {
            client_id: client_id.to_string(),
            token: token.to_string(),
        })
    }

    #[must_use]
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    #[must_use]
    pub fn token(&self) -> &str {
        &self.token
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAuthError {
    MissingClientId,
    MissingBearerToken,
    InvalidBearerToken,
    MissingScopeContract,
    InsufficientScope,
}

impl RemoteAuthError {
    #[must_use]
    pub const fn status_code(self) -> StatusCode {
        match self {
            Self::MissingClientId | Self::MissingBearerToken | Self::InvalidBearerToken => {
                StatusCode::UNAUTHORIZED
            }
            Self::MissingScopeContract | Self::InsufficientScope => StatusCode::FORBIDDEN,
        }
    }
}

impl fmt::Display for RemoteAuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingClientId => write!(f, "remote client id is required"),
            Self::MissingBearerToken => write!(f, "remote bearer token is required"),
            Self::InvalidBearerToken => write!(f, "remote bearer token is invalid"),
            Self::MissingScopeContract => write!(f, "remote route scope contract is missing"),
            Self::InsufficientScope => write!(f, "remote client scope is insufficient"),
        }
    }
}

impl Error for RemoteAuthError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteAuthDecision {
    pub client_id: String,
    pub target: RemoteAuthTarget,
    pub required_scope: RemoteAccessScope,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteAuthTarget {
    Http {
        method: &'static str,
        path: &'static str,
    },
    WsHandshake,
    WsMethod {
        method: String,
    },
}

/// Authorize a remote client for an HTTP daemon route.
///
/// # Errors
/// Returns [`RemoteAuthError::MissingScopeContract`] when the route has no
/// remote scope contract, or [`RemoteAuthError::InsufficientScope`] when the
/// client lacks the required scope.
pub fn authorize_remote_http_route(
    client: &RemoteStoredClient,
    route: &'static HttpApiRouteContract,
) -> Result<RemoteAuthDecision, RemoteAuthError> {
    let required_scope = first_required_scope(remote_http_scopes(route))?;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::Http {
            method: route.method.as_str(),
            path: route.path,
        },
        required_scope,
    })
}

/// Authorize the remote WebSocket handshake itself.
///
/// # Errors
/// Returns [`RemoteAuthError::InsufficientScope`] when the client lacks read
/// access to the `/v1/ws` route.
pub fn authorize_remote_ws_handshake(
    client: &RemoteStoredClient,
) -> Result<RemoteAuthDecision, RemoteAuthError> {
    let required_scope = RemoteAccessScope::Read;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::WsHandshake,
        required_scope,
    })
}

/// Authorize one JSON-RPC method received on an authenticated remote WebSocket.
///
/// # Errors
/// Returns [`RemoteAuthError::MissingScopeContract`] when the method has no
/// remote scope contract, or [`RemoteAuthError::InsufficientScope`] when the
/// client lacks the required scope.
pub fn authorize_remote_ws_method(
    client: &RemoteStoredClient,
    method: &str,
) -> Result<RemoteAuthDecision, RemoteAuthError> {
    let required_scope = first_required_scope(remote_ws_scopes(method))?;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::WsMethod {
            method: method.to_string(),
        },
        required_scope,
    })
}

fn first_required_scope(
    scopes: Option<&'static [RemoteAccessScope]>,
) -> Result<RemoteAccessScope, RemoteAuthError> {
    scopes
        .and_then(|scopes| scopes.first().copied())
        .ok_or(RemoteAuthError::MissingScopeContract)
}

fn authorize_client_scope(
    client: &RemoteStoredClient,
    required_scope: RemoteAccessScope,
) -> Result<(), RemoteAuthError> {
    if client.scopes.contains(&required_scope) {
        return Ok(());
    }
    Err(RemoteAuthError::InsufficientScope)
}

#[expect(
    dead_code,
    reason = "documents that WSS handshakes share the HTTP route contract"
)]
fn ws_route_path() -> &'static str {
    http_paths::WS
}
