use axum::http::StatusCode;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{RemoteAuditOutcome, RemoteAuditScopeDecision};
use crate::daemon::remote_pairing::{RemotePairingCode, RemotePairingRecord};

use super::test_http_state_with_db;

#[tokio::test]
async fn remote_pair_status_is_public_redacted_and_audited() {
    let state = remote_pairing_status_state();
    let code = seed_pending_pairing(&state, "pairing-status-pending");
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_STATUS))
        .header("x-request-id", "request-pair-status-pending")
        .json(&serde_json::json!({ "pairing_id": "pairing-status-pending" }))
        .send()
        .await
        .expect("send pairing status request");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("pairing status body");
    assert_eq!(body, serde_json::json!({ "status": "pending" }));
    assert!(!body.to_string().contains(code.expose()));

    let audit = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .find(|event| event.route_or_method == "remote.pair.status")
        .expect("pairing status audit");
    assert_eq!(
        audit.request_id.as_deref(),
        Some("request-pair-status-pending")
    );
    assert!(audit.client_id.is_none());
    assert_eq!(audit.scope, RemoteAccessScope::Read);
    assert_eq!(audit.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(audit.outcome, RemoteAuditOutcome::Success);
    assert_eq!(audit.remote_addr.as_deref(), Some("127.0.0.1"));
    assert!(audit.error_detail.is_none());

    server.abort();
}

#[tokio::test]
async fn remote_pair_status_collapses_unknown_ids_to_unavailable() {
    let state = remote_pairing_status_state();
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_STATUS))
        .header("x-request-id", "request-pair-status-unknown")
        .json(&serde_json::json!({ "pairing_id": "unknown-pairing-id" }))
        .send()
        .await
        .expect("send unknown pairing status request");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("unknown pairing status body");
    assert_eq!(body, serde_json::json!({ "status": "unavailable" }));

    let audit = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .find(|event| event.route_or_method == "remote.pair.status")
        .expect("unknown pairing status audit");
    assert_eq!(audit.outcome, RemoteAuditOutcome::Failure);
    assert_eq!(
        audit.error_detail.as_deref(),
        Some("remote pairing status unavailable")
    );

    server.abort();
}

#[tokio::test]
async fn remote_pair_status_fails_closed_without_remote_config() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_STATUS))
        .json(&serde_json::json!({ "pairing_id": "pairing-status-local" }))
        .send()
        .await
        .expect("send local pairing status request");

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("local pairing status body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING_CONFIG");

    server.abort();
}

fn remote_pairing_status_state() -> crate::daemon::http::DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
    state
}

fn seed_pending_pairing(
    state: &crate::daemon::http::DaemonHttpState,
    pairing_id: &str,
) -> RemotePairingCode {
    let code = RemotePairingCode::from_value_for_tests("pairing-status-secret");
    let record = RemotePairingRecord::new_for_tests(
        pairing_id,
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        code.expose(),
        "2026-07-13T12:00:00Z",
        "2099-07-13T12:10:00Z",
    )
    .expect("pairing record");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .create_remote_pairing_code(&record, "audit-create-pairing-status")
        .expect("create pairing");
    code
}

async fn serve_http(state: crate::daemon::http::DaemonHttpState) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let app = super::super::daemon_http_router(state)
        .into_make_service_with_connect_info::<crate::daemon::http::DaemonConnectInfo>();
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}
