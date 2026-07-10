use super::*;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::ws_methods;
use crate::daemon::protocol::{WsRequest, current_control_plane_actor_id};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{RemoteStoredClient, RemoteTokenHash};
use std::sync::{Arc, Mutex};
use std::thread;

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
    let mut state = super::super::test_support::test_ws_state();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client(
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    ))));
    let request = ws_request("req-read", ws_methods::PING);

    let response = dispatch(&request, &state, &connection).await;

    assert!(response.error.is_none());
    assert_eq!(response.result.expect("ping result")["pong"], true);
}

#[tokio::test]
async fn remote_ws_dispatch_denies_viewer_write_method() {
    let mut state = super::super::test_support::test_ws_state();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let connection = Arc::new(Mutex::new(ConnectionState::new_remote(remote_client(
        "viewer",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
    ))));
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
    let mut state = super::super::test_support::test_ws_state();
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
async fn remote_ws_dispatch_preserves_unknown_method_errors() {
    let mut state = super::super::test_support::test_ws_state();
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
#[should_panic(expected = "connection lock")]
fn remote_ws_dispatch_panics_on_poisoned_connection_lock() {
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let poisoned_connection = Arc::clone(&connection);
    let _ = thread::spawn(move || {
        let _guard = poisoned_connection
            .lock()
            .expect("poison test connection lock");
        panic!("poison websocket connection state");
    })
    .join();

    let _ = remote_client_for_connection(&connection);
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
