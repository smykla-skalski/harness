use std::{error::Error, fmt};

use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};

use super::protocol::{HTTP_API_CONTRACT, HttpApiRouteContract, http_paths};
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
        let mut authorization_parts = authorization.split_whitespace();
        let scheme = authorization_parts
            .next()
            .ok_or(RemoteAuthError::InvalidBearerToken)?;
        let token = authorization_parts
            .next()
            .ok_or(RemoteAuthError::InvalidBearerToken)?;
        if !scheme.eq_ignore_ascii_case("Bearer") || authorization_parts.next().is_some() {
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
    Execution {
        operation: &'static str,
    },
}

/// Authorize a paired execution coordinator for one private executor operation.
///
/// Execution credentials carry only [`RemoteAccessScope::Execute`]. They do
/// not inherit daemon read, write, or administration authority.
///
/// # Errors
/// Returns [`RemoteAuthError::InsufficientScope`] unless the client has the
/// dedicated executor scope.
pub fn authorize_remote_execution_operation(
    client: &RemoteStoredClient,
    operation: &'static str,
) -> Result<RemoteAuthDecision, RemoteAuthError> {
    let required_scope = RemoteAccessScope::Execute;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::Execution { operation },
        required_scope,
    })
}

/// Authorize a remote client for an HTTP daemon route.
///
/// # Errors
/// Returns [`RemoteAuthError::MissingScopeContract`] when the route has no
/// remote scope contract, or [`RemoteAuthError::InsufficientScope`] when the
/// client lacks the required scope.
pub fn authorize_remote_http_route(
    client: &RemoteStoredClient,
    route: &HttpApiRouteContract,
) -> Result<RemoteAuthDecision, RemoteAuthError> {
    let required_scope = remote_http_required_scope(route)?;
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
    let required_scope = remote_ws_handshake_scope()?;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::WsHandshake,
        required_scope,
    })
}

/// Return the remote scope required to establish the WebSocket connection.
///
/// # Errors
/// Returns [`RemoteAuthError::MissingScopeContract`] when the `/v1/ws` HTTP
/// route is missing or lacks a remote scope contract.
pub fn remote_ws_handshake_scope() -> Result<RemoteAccessScope, RemoteAuthError> {
    let route = HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == http_paths::WS)
        .ok_or(RemoteAuthError::MissingScopeContract)?;
    first_required_scope(remote_http_scopes(route))
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
    let required_scope = remote_ws_required_scope(method)?;
    authorize_client_scope(client, required_scope)?;
    Ok(RemoteAuthDecision {
        client_id: client.client_id.clone(),
        target: RemoteAuthTarget::WsMethod {
            method: method.to_string(),
        },
        required_scope,
    })
}

pub(crate) fn remote_http_required_scope(
    route: &HttpApiRouteContract,
) -> Result<RemoteAccessScope, RemoteAuthError> {
    first_required_scope(remote_http_scopes(route))
}

pub(crate) fn remote_ws_required_scope(method: &str) -> Result<RemoteAccessScope, RemoteAuthError> {
    first_required_scope(remote_ws_scopes(method))
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
