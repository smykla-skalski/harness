use std::sync::{Arc, Mutex};

use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::protocol::{WsRequest, ws_methods};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::remote_ws_required_scope;
use crate::daemon::remote_identity::{RemoteClientRegistration, RemoteStoredClient};
use crate::daemon::websocket::connection::ConnectionState;

use super::super::{RemoteWsAllowedAudit, authorize_remote_ws_request, dispatch};

#[tokio::test]
async fn remote_ws_authz_matrix_denies_missing_client_for_every_method() {
    let mut state = crate::daemon::websocket::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));

    for method in ws_methods::ALL {
        let request = ws_request(method);
        let response = authorize_remote_ws_request(
            &request,
            &state,
            &connection,
            RemoteWsAllowedAudit::Success,
        )
        .await
        .expect_err("missing remote client must be denied");
        assert_remote_auth_error(&response, 401, method);
    }
}

#[tokio::test]
async fn remote_ws_authz_matrix_enforces_every_method_scope() {
    let mut state = crate::daemon::websocket::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let clients = MatrixClients::register(&state);

    for method in ws_methods::ALL {
        let required_scope = remote_ws_required_scope(method).expect("declared method scope");
        let denied = clients.denied(required_scope);
        let request = ws_request(method);
        let response =
            authorize_remote_ws_request(&request, &state, denied, RemoteWsAllowedAudit::Success)
                .await
                .expect_err("insufficient remote scope must be denied");
        assert_remote_auth_error(&response, 403, method);

        authorize_remote_ws_request(
            &request,
            &state,
            clients.allowed(required_scope),
            RemoteWsAllowedAudit::Success,
        )
        .await
        .unwrap_or_else(|response| {
            panic!(
                "{method} rejected allowed {} scope: {response:?}",
                required_scope.as_str()
            );
        });
    }
}

#[tokio::test]
async fn remote_ws_authz_matrix_routes_github_status_after_authorization() {
    let mut state = crate::daemon::websocket::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let viewer = registered_client(&state, "github-viewer", RemoteRole::Viewer, &[]);
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(viewer)));
    let response = dispatch(&ws_request(ws_methods::GITHUB_STATUS), &state, &connection).await;

    assert!(
        response.error.is_none(),
        "github.status did not reach its declared websocket handler: {:?}",
        response.error
    );
}

struct MatrixClients {
    viewer: Arc<Mutex<ConnectionState>>,
    operator: Arc<Mutex<ConnectionState>>,
    admin: Arc<Mutex<ConnectionState>>,
    write_only: Arc<Mutex<ConnectionState>>,
    executor: Arc<Mutex<ConnectionState>>,
}

impl MatrixClients {
    fn register(state: &DaemonHttpState) -> Self {
        Self {
            viewer: connection(registered_client(state, "viewer", RemoteRole::Viewer, &[])),
            operator: connection(registered_client(
                state,
                "operator",
                RemoteRole::Operator,
                &[],
            )),
            admin: connection(registered_client(state, "admin", RemoteRole::Admin, &[])),
            write_only: connection(registered_client(
                state,
                "write-only",
                RemoteRole::Operator,
                &[RemoteAccessScope::Write],
            )),
            executor: connection(registered_client(
                state,
                "executor",
                RemoteRole::ExecutionCoordinator,
                &[],
            )),
        }
    }

    fn allowed(&self, scope: RemoteAccessScope) -> &Arc<Mutex<ConnectionState>> {
        match scope {
            RemoteAccessScope::Read => &self.viewer,
            RemoteAccessScope::Write => &self.operator,
            RemoteAccessScope::Admin => &self.admin,
            RemoteAccessScope::Execute => &self.executor,
        }
    }

    fn denied(&self, scope: RemoteAccessScope) -> &Arc<Mutex<ConnectionState>> {
        match scope {
            RemoteAccessScope::Read | RemoteAccessScope::Admin => &self.write_only,
            RemoteAccessScope::Write | RemoteAccessScope::Execute => &self.viewer,
        }
    }
}

fn registered_client(
    state: &DaemonHttpState,
    client_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
) -> RemoteStoredClient {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "Authorization Matrix",
        "test",
        role,
        scopes,
        &format!("remote-authz-matrix-token-{client_id}-abcdefghijklmnopqrstuvwxyz"),
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
        .expect("register matrix client")
}

fn connection(client: RemoteStoredClient) -> Arc<Mutex<ConnectionState>> {
    Arc::new(Mutex::new(ConnectionState::new_remote(client)))
}

fn ws_request(method: &str) -> WsRequest {
    WsRequest {
        id: format!("authz-matrix-{method}"),
        method: method.to_string(),
        params: serde_json::json!({}),
        trace_context: None,
    }
}

fn assert_remote_auth_error(
    response: &crate::daemon::protocol::WsResponse,
    status: u16,
    method: &str,
) {
    let error = response.error.as_ref().unwrap_or_else(|| {
        panic!("{method} did not return a remote authorization error");
    });
    assert_eq!(error.code, "REMOTE_AUTH", "{method}");
    assert_eq!(error.status_code, Some(status), "{method}");
    assert!(response.result.is_none(), "{method}");
}
