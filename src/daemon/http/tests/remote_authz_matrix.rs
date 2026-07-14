use axum::Router;
use axum::http::{HeaderMap, HeaderValue, StatusCode, header::AUTHORIZATION};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};

use crate::daemon::http::auth::{DaemonHttpAuthMode, authorize_http_route};
use crate::daemon::protocol::{
    HTTP_API_CONTRACT, HttpApiRouteContract, HttpRouteMethod, http_paths,
};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole, remote_http_scopes};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::test_http_state_with_db;

#[test]
fn remote_http_authz_matrix_enforces_every_private_route() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_matrix_clients(&state);

    let public_routes = HTTP_API_CONTRACT
        .iter()
        .filter(|route| is_public_pairing_route(route))
        .collect::<Vec<_>>();
    assert_eq!(
        public_routes
            .iter()
            .map(|route| route.path)
            .collect::<Vec<_>>(),
        vec![
            http_paths::REMOTE_PAIR_CLAIM,
            http_paths::REMOTE_PAIR_STATUS,
        ]
    );

    for route in HTTP_API_CONTRACT
        .iter()
        .filter(|route| !is_public_pairing_route(route))
    {
        assert_missing_credentials_denied(&state, route);
        let required_scope = required_scope(route);
        assert_insufficient_scope_denied(&state, route, required_scope);
        assert_allowed_scope_accepted(&state, route, required_scope);
    }
}

#[tokio::test]
async fn remote_http_authz_matrix_protects_every_sse_route() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_matrix_clients(&state);
    let (base_url, server) = serve_http(state).await;

    for path in [http_paths::STREAM, http_paths::SESSION_STREAM] {
        let path = path.replace("{session_id}", "missing-session");
        assert_sse_status(&base_url, &path, None, StatusCode::UNAUTHORIZED).await;
        assert_sse_status(&base_url, &path, Some("write-only"), StatusCode::FORBIDDEN).await;
        assert_sse_status(&base_url, &path, Some("viewer"), StatusCode::OK).await;
    }

    server.abort();
    let _ = server.await;
}

fn assert_missing_credentials_denied(
    state: &crate::daemon::http::DaemonHttpState,
    route: &HttpApiRouteContract,
) {
    let response = authorize_http_route(&HeaderMap::new(), state, route)
        .expect_err("missing credentials must be denied");
    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "{} {}",
        route.method.as_str(),
        route.path
    );
}

fn assert_insufficient_scope_denied(
    state: &crate::daemon::http::DaemonHttpState,
    route: &HttpApiRouteContract,
    required_scope: RemoteAccessScope,
) {
    let client_id = match required_scope {
        RemoteAccessScope::Read | RemoteAccessScope::Admin => "write-only",
        RemoteAccessScope::Write => "viewer",
    };
    let response = authorize_http_route(&remote_headers(client_id), state, route)
        .expect_err("insufficient scope must be denied");
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "{} {} requires {}",
        route.method.as_str(),
        route.path,
        required_scope.as_str()
    );
}

fn assert_allowed_scope_accepted(
    state: &crate::daemon::http::DaemonHttpState,
    route: &HttpApiRouteContract,
    required_scope: RemoteAccessScope,
) {
    let client_id = match required_scope {
        RemoteAccessScope::Read => "viewer",
        RemoteAccessScope::Write => "operator",
        RemoteAccessScope::Admin => "admin",
    };
    authorize_http_route(&remote_headers(client_id), state, route).unwrap_or_else(|response| {
        panic!(
            "{} {} rejected allowed {} scope with {}",
            route.method.as_str(),
            route.path,
            required_scope.as_str(),
            response.status()
        );
    });
}

fn required_scope(route: &HttpApiRouteContract) -> RemoteAccessScope {
    remote_http_scopes(route)
        .and_then(|scopes| scopes.first().copied())
        .unwrap_or_else(|| {
            panic!(
                "{} {} is missing a remote scope",
                route.method.as_str(),
                route.path
            );
        })
}

fn is_public_pairing_route(route: &HttpApiRouteContract) -> bool {
    route.method == HttpRouteMethod::Post
        && matches!(
            route.path,
            http_paths::REMOTE_PAIR_CLAIM | http_paths::REMOTE_PAIR_STATUS
        )
}

fn register_matrix_clients(state: &crate::daemon::http::DaemonHttpState) {
    for (client_id, role, scopes) in [
        ("viewer", RemoteRole::Viewer, &[][..]),
        ("operator", RemoteRole::Operator, &[][..]),
        ("admin", RemoteRole::Admin, &[][..]),
        (
            "write-only",
            RemoteRole::Operator,
            &[RemoteAccessScope::Write][..],
        ),
    ] {
        let registration = RemoteClientRegistration::new_for_tests(
            client_id,
            "Authorization Matrix",
            "test",
            role,
            scopes,
            &remote_token(client_id),
            "2026-07-14T08:00:00Z",
        )
        .expect("matrix registration");
        state
            .db
            .get()
            .expect("db slot")
            .lock()
            .expect("db lock")
            .register_remote_client(&registration)
            .expect("register matrix client");
    }
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
    format!("remote-authz-matrix-token-{client_id}-abcdefghijklmnopqrstuvwxyz")
}

async fn assert_sse_status(
    base_url: &str,
    path: &str,
    client_id: Option<&str>,
    expected: StatusCode,
) {
    let client = reqwest::Client::new();
    let mut request = client.get(format!("{base_url}{path}"));
    if let Some(client_id) = client_id {
        request = request
            .header(REMOTE_CLIENT_ID_HEADER, client_id)
            .bearer_auth(remote_token(client_id));
    }
    let response = timeout(Duration::from_secs(5), request.send())
        .await
        .expect("SSE auth response timed out")
        .expect("send SSE request");
    assert_eq!(response.status(), expected, "GET {path}");
    if expected == StatusCode::OK {
        assert_eq!(
            response
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some("text/event-stream")
        );
    }
}

async fn serve_http(state: crate::daemon::http::DaemonHttpState) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router(state);
    serve_router(app).await
}

async fn serve_router(app: Router) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener address");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}
