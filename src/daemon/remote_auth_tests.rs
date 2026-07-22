use axum::http::{HeaderMap, HeaderValue, StatusCode, header::AUTHORIZATION};

use super::{
    REMOTE_CLIENT_ID_HEADER, RemoteAuthError, RemoteAuthTarget, RemoteBearerCredentials,
    authorize_remote_execution_operation, authorize_remote_http_route, authorize_remote_ws_method,
};
use crate::daemon::protocol::{
    HTTP_API_CONTRACT, HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths,
    ws_methods,
};
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
        typed_status(
            RemoteBearerCredentials::from_headers(&non_bearer)
                .expect_err("non-bearer")
                .status_code()
        ),
        StatusCode::UNAUTHORIZED
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

    let mut extra_parts = HeaderMap::new();
    extra_parts.insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_static("client-1"),
    );
    extra_parts.insert(
        AUTHORIZATION,
        HeaderValue::from_static("Bearer remote-token-secret extra"),
    );
    assert_eq!(
        RemoteBearerCredentials::from_headers(&extra_parts).expect_err("extra bearer parts"),
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
fn remote_http_authz_accepts_borrowed_route_contracts() {
    let route = HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::STREAM,
        parity: HttpRouteParity::Exempt {
            reason: "stack-local test route",
        },
        swift_client_exposed: false,
    };
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);

    let decision = authorize_remote_http_route(&viewer, &route).expect("borrowed route");

    assert_eq!(
        decision.target,
        RemoteAuthTarget::Http {
            method: "GET",
            path: http_paths::STREAM,
        }
    );
    assert_eq!(decision.required_scope, RemoteAccessScope::Read);
}

#[test]
fn remote_http_authz_denies_insufficient_scope_with_403() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let telemetry = http_route(http_paths::DAEMON_TELEMETRY);

    let error =
        authorize_remote_http_route(&viewer, telemetry).expect_err("viewer cannot write telemetry");

    assert_eq!(error, RemoteAuthError::InsufficientScope);
    assert_eq!(typed_status(error.status_code()), StatusCode::FORBIDDEN);
}

#[test]
fn remote_ws_authz_covers_http_handshake_and_per_message_scope() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let operator = remote_client(
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    );

    assert_eq!(
        authorize_remote_http_route(&viewer, http_route(http_paths::WS))
            .expect("viewer handshake")
            .target,
        RemoteAuthTarget::Http {
            method: "GET",
            path: http_paths::WS,
        }
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
fn automation_observability_scope_matrix_protects_run_detail() {
    let viewer = remote_client("viewer", RemoteRole::Viewer, &[RemoteAccessScope::Read]);
    let operator = remote_client(
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    );

    for (path, method) in [
        (
            http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
            ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
        ),
        (
            http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
            ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
        ),
    ] {
        assert_eq!(
            authorize_remote_http_route(&viewer, http_route(path))
                .expect("viewer HTTP read")
                .required_scope,
            RemoteAccessScope::Read
        );
        assert_eq!(
            authorize_remote_ws_method(&viewer, method)
                .expect("viewer websocket read")
                .required_scope,
            RemoteAccessScope::Read
        );
    }

    let detail_route = http_route(http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL);
    assert_eq!(
        authorize_remote_http_route(&viewer, detail_route)
            .expect_err("viewer cannot read raw run detail"),
        RemoteAuthError::InsufficientScope
    );
    assert_eq!(
        authorize_remote_ws_method(&viewer, ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL)
            .expect_err("viewer cannot read raw websocket run detail"),
        RemoteAuthError::InsufficientScope
    );
    assert_eq!(
        authorize_remote_http_route(&operator, detail_route)
            .expect("operator HTTP detail")
            .required_scope,
        RemoteAccessScope::Write
    );
    assert_eq!(
        authorize_remote_ws_method(&operator, ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL)
            .expect("operator websocket detail")
            .required_scope,
        RemoteAccessScope::Write
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
    assert_eq!(typed_status(error.status_code()), StatusCode::FORBIDDEN);
}

#[test]
fn execution_scope_authorizes_only_private_executor_operations() {
    let executor = remote_client(
        "executor",
        RemoteRole::ExecutionCoordinator,
        &[RemoteAccessScope::Execute],
    );

    let decision = authorize_remote_execution_operation(&executor, "offer")
        .expect("dedicated executor operation");
    assert_eq!(decision.required_scope, RemoteAccessScope::Execute);
    assert_eq!(
        decision.target,
        RemoteAuthTarget::Execution { operation: "offer" }
    );
    assert_eq!(
        authorize_remote_http_route(&executor, http_route(http_paths::READY))
            .expect_err("executor must not read daemon routes"),
        RemoteAuthError::InsufficientScope
    );

    for (role, scopes) in [
        (RemoteRole::Viewer, vec![RemoteAccessScope::Read]),
        (
            RemoteRole::Operator,
            vec![RemoteAccessScope::Read, RemoteAccessScope::Write],
        ),
        (
            RemoteRole::Admin,
            vec![
                RemoteAccessScope::Read,
                RemoteAccessScope::Write,
                RemoteAccessScope::Admin,
            ],
        ),
    ] {
        let client = remote_client(role.as_str(), role, &scopes);
        assert_eq!(
            authorize_remote_execution_operation(&client, "claim")
                .expect_err("generic daemon role must not execute"),
            RemoteAuthError::InsufficientScope
        );
    }
}

#[test]
fn revoked_execution_coordinator_token_cannot_be_reauthenticated() {
    let db = crate::daemon::db::DaemonDb::open_in_memory().expect("daemon database");
    let registration = crate::daemon::remote_identity::RemoteClientRegistration::new_for_tests(
        "executor-revoked",
        "Remote executor",
        "linux",
        RemoteRole::ExecutionCoordinator,
        &[],
        "executor-token-secret",
        "2026-07-19T12:00:00Z",
    )
    .expect("executor registration");
    db.register_remote_client(&registration)
        .expect("register executor");
    assert!(
        db.verify_remote_client_token("executor-revoked", "executor-token-secret")
            .expect("verify active executor")
            .is_some()
    );

    assert!(
        db.revoke_remote_client("executor-revoked", "2026-07-19T12:01:00Z")
            .expect("revoke executor")
    );
    assert!(
        db.verify_remote_client_token("executor-revoked", "executor-token-secret")
            .expect("verify revoked executor")
            .is_none()
    );
}

fn typed_status(status: StatusCode) -> StatusCode {
    status
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
