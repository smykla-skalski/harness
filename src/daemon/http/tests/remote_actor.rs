use axum::http::StatusCode;
use axum::{Router, middleware, routing::get};
use tokio::net::TcpListener;

use crate::daemon::http::auth::DaemonHttpAuthMode;
use crate::daemon::protocol::{current_control_plane_actor_id, http_paths};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::test_http_state_with_db;

#[tokio::test]
async fn remote_http_authz_scopes_authenticated_actor_identity() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    register_operator(&state);
    let app = Router::new()
        .route(http_paths::HEALTH, get(current_actor))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            super::super::auth::authorize_remote_http_request,
        ))
        .with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let address = listener.local_addr().expect("listener address");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });

    let response = reqwest::Client::new()
        .get(format!("http://{address}{}", http_paths::HEALTH))
        .header(REMOTE_CLIENT_ID_HEADER, "operator")
        .bearer_auth(remote_token())
        .send()
        .await
        .expect("send health request");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.text().await.expect("actor response"),
        r#"{"client_id":"operator","platform":"ios","role":"operator","scopes":["read","write"]}"#
    );
    server.abort();
    let _ = server.await;
}

fn register_operator(state: &crate::daemon::http::DaemonHttpState) {
    let registration = RemoteClientRegistration::new_for_tests(
        "operator",
        "Phone",
        "ios",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        &remote_token(),
        "2026-06-21T16:00:00Z",
    )
    .expect("remote registration");
    let db = state.db.get().expect("db slot").lock().expect("db lock");
    db.register_remote_client(&registration)
        .expect("register remote client");
}

fn remote_token() -> String {
    "remote-token-secret-operator".to_string()
}

async fn current_actor() -> String {
    current_control_plane_actor_id()
}
