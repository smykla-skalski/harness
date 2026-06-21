use axum::http::{HeaderMap, HeaderValue, header::AUTHORIZATION};

use super::{
    REMOTE_CLIENT_ID_HEADER, RemoteAuthError, RemoteAuthTarget, RemoteBearerCredentials,
    authorize_remote_http_route, authorize_remote_ws_handshake, authorize_remote_ws_method,
};
use crate::daemon::protocol::{HTTP_API_CONTRACT, http_paths, ws_methods};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{RemoteStoredClient, RemoteTokenHash};

#[test]
fn remote_bearer_credentials_require_client_id_and_bearer_token() {
    let empty_headers = HeaderMap::new();

    assert_eq!(
        RemoteBearerCredentials::from_headers(&empty_headers).expect_err("missing credentials"),
        RemoteAuthError::MissingClientId
    );

    let mut missing_bearer = HeaderMap::new();
    missing_bearer.insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_static("client-1"),
    );
    assert_eq!(
        RemoteBearerCredentials::from_headers(&missing_bearer).expect_err("missing bearer"),
        RemoteAuthError::MissingBearerToken
    );

    let mut non_bearer = missing_bearer.clone();
    non_bearer.insert(AUTHORIZATION, HeaderValue::from_static("Basic abc"));
    assert_eq!(
        RemoteBearerCredentials::from_headers(&non_bearer).expect_err("non-bearer").status_code(),
        401
    );
    assert_eq!(
        RemoteBearerCredentials::from_headers(&non_bearer).expect_err("non-bearer"),
        RemoteAuthError::InvalidBearerToken
    );

    let mut blank_bearer = missing_bearer;
    blank_bearer.insert(AUTHORIZATION, HeaderValue::from_static("Bearer "));
    assert_eq!(
        RemoteBearerCredentials::from_headers(&blank_bearer).expect_err("blank bearer"),
        RemoteAuthError::InvalidBearerToken
    );
}

#[test]
fn remote_bearer_credentials_parse_and_redact_debug() {
    let mut headers = HeaderMap::new();
    headers.insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_static("client-1"),
    );
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_static("Bearer remote-token-secret"),
    );

    let credentials = RemoteBearerCredentials::from_headers(&headers).expect("credentials");

    assert_eq!(credentials.client_id(), "client-1");
    assert_eq!(credentials.token(), "remote-token-secret");
    assert!(!format!("{credentials:?}").contains("remote-token-secret"));
}

#[test]
fn remote_http_authz_allows_role_scoped_routes() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let operator = remote_client(
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    );
    let admin = remote_client(
        "admin",
        RemoteRole::Admin,
        &[
            RemoteAccessScope::Read,
            RemoteAccessScope::Write,
            RemoteAccessScope::Admin,
        ],
    );

    let stream = http_route(http_paths::STREAM);
    let telemetry = http_route(http_paths::DAEMON_TELEMETRY);
    let stop = http_route(http_paths::DAEMON_STOP);

    assert_eq!(
        authorize_remote_http_route(&viewer, stream)
            .expect("viewer stream")
            .required_scope,
        RemoteAccessScope::Read
    );
    assert_eq!(
        authorize_remote_http_route(&operator, telemetry)
            .expect("operator telemetry")
            .required_scope,
        RemoteAccessScope::Write
    );
    assert_eq!(
        authorize_remote_http_route(&admin, stop)
            .expect("admin stop")
            .required_scope,
        RemoteAccessScope::Admin
    );
}

#[test]
fn remote_http_authz_denies_insufficient_scope_with_403() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let telemetry = http_route(http_paths::DAEMON_TELEMETRY);

    let error =
        authorize_remote_http_route(&viewer, telemetry).expect_err("viewer cannot write telemetry");

    assert_eq!(error, RemoteAuthError::InsufficientScope);
    assert_eq!(error.status_code(), 403);
}

#[test]
fn remote_ws_authz_covers_handshake_and_per_message_scope() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let operator = remote_client(
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    );

    assert_eq!(
        authorize_remote_ws_handshake(&viewer)
            .expect("viewer handshake")
            .target,
        RemoteAuthTarget::WsHandshake
    );
    assert_eq!(
        authorize_remote_ws_method(&viewer, ws_methods::SESSIONS)
            .expect("viewer read")
            .required_scope,
        RemoteAccessScope::Read
    );
    assert_eq!(
        authorize_remote_ws_method(&operator, ws_methods::SESSION_START)
            .expect("operator write")
            .required_scope,
        RemoteAccessScope::Write
    );
    assert_eq!(
        authorize_remote_ws_method(&viewer, ws_methods::SESSION_START)
            .expect_err("viewer cannot start session"),
        RemoteAuthError::InsufficientScope
    );
}

#[test]
fn remote_authz_fails_closed_when_scope_contract_is_missing() {
    let admin = remote_client(
        "admin",
        RemoteRole::Admin,
        &[
            RemoteAccessScope::Read,
            RemoteAccessScope::Write,
            RemoteAccessScope::Admin,
        ],
    );

    let error =
        authorize_remote_ws_method(&admin, "remote.unscoped").expect_err("unscoped method denied");

    assert_eq!(error, RemoteAuthError::MissingScopeContract);
    assert_eq!(error.status_code(), 403);
}

fn http_route(path: &str) -> &'static crate::daemon::protocol::HttpApiRouteContract {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == path)
        .expect("http route contract")
}

fn remote_client(
    client_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
) -> RemoteStoredClient {
    RemoteStoredClient {
        client_id: client_id.to_string(),
        display_name: "MacBook Pro".to_string(),
        platform: "macos".to_string(),
        role,
        scopes: scopes.to_vec(),
        token_hash: RemoteTokenHash::from_token_for_tests("remote-token-secret"),
        token_hint: "secret".to_string(),
        created_at: "2026-06-21T16:00:00Z".to_string(),
        last_seen_at: None,
        revoked_at: None,
        rotated_at: None,
    }
}
