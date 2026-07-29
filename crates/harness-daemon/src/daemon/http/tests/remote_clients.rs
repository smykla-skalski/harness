use reqwest::StatusCode;
use serde_json::Value;

use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteRole;
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::{RemoteAuditOutcome, RemoteAuditScopeDecision};

use super::remote_viewer_support::{register_remote_client, serve_http};
use super::test_http_state_with_db;

const VIEWER_ID: &str = "self-revoking-viewer";
const OPERATOR_ID: &str = "unrelated-operator";

#[tokio::test]
async fn remote_client_self_revoke_revokes_only_authenticated_client_and_audits() {
    let mut state = test_http_state_with_db();
    state.auth_mode = crate::daemon::http::DaemonHttpAuthMode::Remote;
    register_remote_client(&state, VIEWER_ID, RemoteRole::Viewer);
    register_remote_client(&state, OPERATOR_ID, RemoteRole::Operator);
    let assertion_state = state.clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let response = client
        .post(format!(
            "{base_url}{}",
            http_paths::REMOTE_CLIENT_SELF_REVOKE
        ))
        .header("x-request-id", "remote-self-revoke-request")
        .header(REMOTE_CLIENT_ID_HEADER, VIEWER_ID)
        .bearer_auth(remote_token(VIEWER_ID))
        .send()
        .await
        .expect("send self-revoke request");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.json::<Value>().await.expect("self-revoke json");
    assert_eq!(body["client_id"], VIEWER_ID);
    assert!(
        body["revoked_at"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
    );

    let second_response = client
        .post(format!(
            "{base_url}{}",
            http_paths::REMOTE_CLIENT_SELF_REVOKE
        ))
        .header(REMOTE_CLIENT_ID_HEADER, VIEWER_ID)
        .bearer_auth(remote_token(VIEWER_ID))
        .send()
        .await
        .expect("retry revoked credential");
    assert_eq!(second_response.status(), StatusCode::UNAUTHORIZED);

    let db = assertion_state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock");
    assert!(
        db.verify_remote_client_token(VIEWER_ID, &remote_token(VIEWER_ID))
            .expect("verify revoked viewer")
            .is_none()
    );
    assert!(
        db.verify_remote_client_token(OPERATOR_ID, &remote_token(OPERATOR_ID))
            .expect("verify unrelated operator")
            .is_some()
    );
    let events = db.load_remote_audit_events(20).expect("load audits");
    let revoke = events
        .iter()
        .find(|event| event.route_or_method == "remote.clients.self_revoke")
        .expect("self-revoke lifecycle audit");
    assert_eq!(
        revoke.request_id.as_deref(),
        Some("remote-self-revoke-request")
    );
    assert_eq!(revoke.client_id.as_deref(), Some(VIEWER_ID));
    assert_eq!(revoke.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(revoke.outcome, RemoteAuditOutcome::Success);

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_client_self_revoke_rejects_local_mode_without_side_effects() {
    let state = test_http_state_with_db();
    register_remote_client(&state, VIEWER_ID, RemoteRole::Viewer);
    let assertion_state = state.clone();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!(
            "{base_url}{}",
            http_paths::REMOTE_CLIENT_SELF_REVOKE
        ))
        .bearer_auth("token")
        .send()
        .await
        .expect("send local self-revoke request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = response
        .json::<Value>()
        .await
        .expect("local rejection json");
    assert_eq!(body["error"]["code"], "REMOTE_CLIENT_REVOKE");
    assert!(
        assertion_state
            .db
            .get()
            .expect("db slot")
            .lock()
            .expect("db lock")
            .verify_remote_client_token(VIEWER_ID, &remote_token(VIEWER_ID))
            .expect("verify viewer")
            .is_some()
    );

    server.abort();
    let _ = server.await;
}

fn remote_token(client_id: &str) -> String {
    format!("remote-token-secret-{client_id}")
}
