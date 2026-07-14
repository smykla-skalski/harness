use super::*;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::ws_methods;
use crate::daemon::protocol::{WsRequest, current_control_plane_actor_id};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{
    RemoteAuditOutcome, RemoteAuditScopeDecision, RemoteClientRegistration, RemoteStoredClient,
    RemoteTokenHash,
};
use std::sync::{Arc, Mutex};
use std::thread;

mod remote_authz_matrix;

#[test]
fn websocket_activity_logging_uses_debug_level() {
    assert_eq!(ws_activity_log_level(), tracing::Level::DEBUG);
}

#[test]
fn ws_request_deserialization() {
    let json = r#"{"id":"abc-123","method":"health","params":{}}"#;
    let request: WsRequest = serde_json::from_str(json).expect("deserialize");
    assert_eq!(request.id, "abc-123");
    assert_eq!(request.method, "health");
}

#[tokio::test]
async fn remote_ws_dispatch_allows_viewer_read_method() {
    let mut state = super::super::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(
        registered_remote_client(
            &state,
            "viewer",
            RemoteRole::Viewer,
            &[RemoteAccessScope::Read],
        ),
    )));
    let request = ws_request("req-read", ws_methods::PING);

    let response = dispatch(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(response.result.expect("ping result")["pong"], true);
}

#[tokio::test]
async fn remote_ws_dispatch_denies_viewer_write_method() {
    let mut state = super::super::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(
        registered_remote_client(
            &state,
            "viewer",
            RemoteRole::Viewer,
            &[RemoteAccessScope::Read],
        ),
    )));
    let request = ws_request("req-write", ws_methods::SESSION_START);

    let response = dispatch(&request, &state, &connection).await;
    let error = response.error.expect("remote auth error");

    assert_eq!(error.code, "REMOTE_AUTH");
    assert_eq!(error.message, "remote client scope is insufficient");
    assert_eq!(error.status_code, Some(403));
    assert!(response.result.is_none());
}

#[tokio::test]
async fn remote_ws_dispatch_denies_known_method_without_remote_client() {
    let mut state = super::super::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = ws_request("req-missing-client", ws_methods::PING);

    let response = dispatch(&request, &state, &connection).await;
    let error = response.error.expect("remote auth error");

    assert_eq!(error.code, "REMOTE_AUTH");
    assert_eq!(error.message, "remote client id is required");
    assert_eq!(error.status_code, Some(401));
    assert!(response.result.is_none());
}

#[tokio::test]
async fn remote_ws_dispatch_denies_client_revoked_after_handshake() {
    let mut state = super::super::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let registration = RemoteClientRegistration::new_for_tests(
        "revoked-viewer",
        "Revoked Viewer",
        "macos",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        "revoked-viewer-token-abcdefghijklmnopqrstuvwxyz",
        "2026-07-12T15:00:00Z",
    )
    .expect("remote registration");
    let authenticated = {
        let db = state.db.get().expect("db slot").lock().expect("db lock");
        let client = db
            .register_remote_client(&registration)
            .expect("register remote client");
        db.revoke_remote_client(&client.client_id, "2026-07-12T15:01:00Z")
            .expect("revoke remote client");
        client
    };
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(authenticated)));
    let request = ws_request("req-revoked", ws_methods::PING);

    let response = dispatch(&request, &state, &connection).await;
    let error = response.error.expect("remote auth error");

    assert_eq!(error.code, "REMOTE_AUTH");
    assert_eq!(error.message, "remote bearer token is invalid");
    assert_eq!(error.status_code, Some(401));
    let audit = state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("load remote audits")
        .into_iter()
        .find(|event| event.request_id.as_deref() == Some("req-revoked"))
        .expect("revoked request audit");
    assert_eq!(audit.client_id.as_deref(), Some("revoked-viewer"));
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        audit.error_detail.as_deref(),
        Some("remote bearer token is invalid")
    );
}

#[tokio::test]
async fn remote_ws_dispatch_reports_auth_store_refresh_failure() {
    let mut state = super::super::test_support::test_http_state();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client(
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    ))));
    let request = ws_request("req-auth-store", ws_methods::PING);

    let response = dispatch(&request, &state, &connection).await;
    let error = response.error.expect("remote auth store error");

    assert_eq!(error.code, "REMOTE_AUTH_STORE");
    assert_eq!(error.message, "remote authentication store is unavailable");
    assert_eq!(error.status_code, Some(503));
}

#[tokio::test]
async fn remote_ws_dispatch_preserves_unknown_method_errors() {
    let mut state = super::super::test_support::test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client(
        "admin",
        RemoteRole::Admin,
        &[
            RemoteAccessScope::Read,
            RemoteAccessScope::Write,
            RemoteAccessScope::Admin,
        ],
    ))));
    let request = ws_request("req-unknown", "remote.unscoped");

    let response = dispatch(&request, &state, &connection).await;
    let error = response.error.expect("unknown method error");

    assert_eq!(error.code, "UNKNOWN_METHOD");
    assert!(error.message.contains("remote.unscoped"));
    assert_eq!(error.status_code, None);
}

#[tokio::test]
async fn remote_ws_dispatch_scopes_authenticated_actor_identity() {
    let mut state = super::super::test_support::test_ws_state();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client(
        "operator",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
    ))));

    let actor = with_connection_actor(&state, &connection, async {
        current_control_plane_actor_id()
    })
    .await;

    assert_eq!(
        actor,
        r#"{"client_id":"operator","platform":"macos","role":"operator","scopes":["read","write"]}"#
    );
}

#[test]
fn remote_ws_dispatch_fails_closed_on_poisoned_connection_lock() {
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let poisoned_connection = Arc::clone(&connection);
    let _ = thread::spawn(move || {
        let _guard = poisoned_connection
            .lock()
            .expect("poison test connection lock");
        panic!("poison websocket connection state");
    })
    .join();

    assert!(remote_client_for_connection(&connection).is_none());
    assert!(remote_viewer_projection_required(&connection));
}

fn ws_request(id: &str, method: &str) -> WsRequest {
    WsRequest {
        id: id.to_string(),
        method: method.to_string(),
        params: serde_json::json!({}),
        trace_context: None,
    }
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
        created_at: "2026-06-21T18:30:00Z".to_string(),
        last_seen_at: None,
        revoked_at: None,
        rotated_at: None,
    }
}

fn registered_remote_client(
    state: &DaemonHttpState,
    client_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
) -> RemoteStoredClient {
    let registration = RemoteClientRegistration::new_for_tests(
        client_id,
        "MacBook Pro",
        "macos",
        role,
        scopes,
        "remote-token-secret",
        "2026-06-21T18:30:00Z",
    )
    .expect("remote client registration");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .register_remote_client(&registration)
        .expect("register remote client")
}
