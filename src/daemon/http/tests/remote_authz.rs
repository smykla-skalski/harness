use std::thread;

use axum::extract::State;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header::AUTHORIZATION};
use axum::{Router, middleware, routing::get};
use rusqlite::Connection;
use serde_json::json;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::http::auth::{DaemonHttpAuthMode, authorize_http_route, require_auth};
use crate::daemon::protocol::{HTTP_API_CONTRACT, HttpApiRouteContract, http_paths};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::{response_json, test_http_state_with_db};

#[tokio::test]
async fn remote_http_authz_denies_missing_credentials_with_401() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;

    let response = authorize_http_route(&HeaderMap::new(), &state, http_route(http_paths::STREAM))
        .expect_err("missing remote credentials");

    let (status, body) = response_json(*response).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"]["code"], "REMOTE_AUTH");
}

#[tokio::test]
async fn remote_http_authz_denies_insufficient_scope_with_403() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );

    let response = authorize_http_route(
        &remote_headers("viewer"),
        &state,
        http_route(http_paths::DAEMON_TELEMETRY),
    )
    .expect_err("viewer cannot write telemetry");

    let (status, body) = response_json(*response).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "REMOTE_AUTH");
}

#[test]
fn remote_http_authz_allows_role_scoped_routes() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    register_remote_client(
        &state,
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    );
    register_remote_client(
        &state,
        "admin",
        RemoteRole::Admin,
        &[
            RemoteAccessScope::Read,
            RemoteAccessScope::Write,
            RemoteAccessScope::Admin,
        ],
    );

    authorize_http_route(
        &remote_headers("viewer"),
        &state,
        http_route(http_paths::STREAM),
    )
    .expect("viewer stream");
    authorize_http_route(
        &remote_headers("operator"),
        &state,
        http_route(http_paths::DAEMON_TELEMETRY),
    )
    .expect("operator telemetry");
    authorize_http_route(
        &remote_headers("admin"),
        &state,
        http_route(http_paths::DAEMON_STOP),
    )
    .expect("admin stop");
}

#[test]
fn remote_http_authz_rejects_revoked_clients() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    {
        let db = state.db.get().expect("db slot").lock().expect("db lock");
        db.revoke_remote_client("viewer", "2026-06-21T17:00:00Z")
            .expect("revoke viewer");
    }

    let response = authorize_http_route(
        &remote_headers("viewer"),
        &state,
        http_route(http_paths::STREAM),
    )
    .expect_err("revoked client rejected");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[test]
fn remote_http_authz_handler_auth_accepts_valid_remote_client_without_local_token() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );

    require_auth(&remote_headers("viewer"), &state)
        .expect("remote client accepted by handler auth");
}

#[tokio::test]
async fn remote_http_authz_router_enforces_route_scope_before_handler() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::DAEMON_TELEMETRY))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .json(&json!({
            "kind": "decode_failure",
            "source": "remote-test",
            "message": "should not reach handler"
        }))
        .send()
        .await
        .expect("send telemetry request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_http_authz_reuses_middleware_client_for_handler_auth() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    let app = Router::new()
        .route(
            http_paths::HEALTH,
            get(poison_store_then_require_handler_auth),
        )
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::auth::authorize_remote_http_request,
        ))
        .with_state(state);
    let (base_url, server) = serve_router(app).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send health request");

    assert_eq!(response.status(), StatusCode::OK);
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_http_authz_preserves_not_found_for_unmatched_routes() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}/v1/not-a-real-route"))
        .send()
        .await
        .expect("send unmatched request");

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_http_authz_treats_head_as_get_scope() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .head(format!("{base_url}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .send()
        .await
        .expect("send health head request");

    assert_eq!(response.status(), StatusCode::OK);
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_http_authz_redacts_poisoned_store_errors() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let db_slot = state.db.clone();
    let _ = thread::spawn(move || {
        let _guard = db_slot.get().expect("db slot").lock().expect("db lock");
        panic!("poison remote client store");
    })
    .join();

    let response = authorize_http_route(
        &remote_headers("viewer"),
        &state,
        http_route(http_paths::STREAM),
    )
    .expect_err("poisoned store rejected");
    assert_redacted_store_error(*response).await;
}

#[tokio::test]
async fn remote_http_authz_redacts_token_verification_store_errors() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_remote_client(
        &state,
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    );
    let db_path = state.db_path.as_ref().expect("db path");
    Connection::open(db_path)
        .expect("open db")
        .execute(
            "UPDATE remote_clients SET token_hash = 'not-a-valid-token-hash' WHERE client_id = 'viewer'",
            [],
        )
        .expect("corrupt token hash");

    let response = authorize_http_route(
        &remote_headers("viewer"),
        &state,
        http_route(http_paths::STREAM),
    )
    .expect_err("store error rejected");
    assert_redacted_store_error(*response).await;
}

fn register_remote_client(
    state: &crate::daemon::http::DaemonHttpState,
    client_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
) {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "MacBook Pro",
        "macos",
        role,
        scopes,
        &remote_token(client_id),
        "2026-06-21T16:00:00Z",
    )
    .expect("remote registration");
    let db = state.db.get().expect("db slot").lock().expect("db lock");
    db.register_remote_client(&registration)
        .expect("register remote client");
}

fn remote_headers(client_id: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        REMOTE_CLIENT_ID_HEADER,
        HeaderValue::from_str(client_id).expect("client id header"),
    );
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {}", remote_token(client_id)))
            .expect("authorization header"),
    );
    headers
}

fn remote_token(client_id: &str) -> String {
    format!("remote-token-secret-{client_id}")
}

async fn serve_http(state: crate::daemon::http::DaemonHttpState) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router(state);
    serve_router(app).await
}

async fn serve_router(app: Router) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}

async fn poison_store_then_require_handler_auth(
    State(state): State<crate::daemon::http::DaemonHttpState>,
    headers: HeaderMap,
) -> StatusCode {
    let db_slot = state.db.clone();
    let _ = thread::spawn(move || {
        let _guard = db_slot.get().expect("db slot").lock().expect("db lock");
        panic!("poison remote client store");
    })
    .join();
    match require_auth(&headers, &state) {
        Ok(()) => StatusCode::OK,
        Err(response) => response.status(),
    }
}

fn http_route(path: &str) -> &'static HttpApiRouteContract {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == path)
        .expect("http route contract")
}

async fn assert_redacted_store_error(response: axum::response::Response) {
    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["code"], "REMOTE_AUTH_STORE");
    assert_eq!(
        body["error"]["message"],
        "remote authentication store is unavailable"
    );
}
