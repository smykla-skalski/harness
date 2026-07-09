use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::{RemoteBearerToken, RemoteClientRegistration};
use crate::daemon::remote_pairing::{
    RemotePairingCode, RemotePairingRateLimiter, RemotePairingRecord,
};

use super::test_http_state_with_db;

#[tokio::test]
async fn remote_pair_claim_is_public_and_returns_one_time_client_token() {
    let state = remote_pairing_state();
    let code = seed_pairing_code(
        &state,
        "pairing-http-success",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        "http-pairing-secret",
        "2026-06-21T18:00:00Z",
        "2099-06-21T18:10:00Z",
    );
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .header("x-forwarded-for", "203.0.113.90")
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "daemon.example.com",
            "client_id": "iphone-1",
            "display_name": "Bart iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send claim request");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.json::<serde_json::Value>().await.expect("json body");
    assert_eq!(body["client_id"], "iphone-1");
    assert_eq!(body["role"], "operator");
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
    let token = body["token"].as_str().expect("paired token");
    assert!(!token.is_empty());
    assert!(!body.to_string().contains(code.expose()));
    assert!(
        db.lock()
            .expect("db lock")
            .verify_remote_client_token("iphone-1", token)
            .expect("verify paired client")
            .is_some()
    );
    let claim_event = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .find(|event| event.route_or_method == "remote.pair.claim")
        .expect("claim audit event");
    assert_eq!(claim_event.remote_addr.as_deref(), Some("127.0.0.1"));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_rejects_replay_and_audits_without_leaking_code() {
    let state = remote_pairing_state();
    let code = seed_pairing_code(
        &state,
        "pairing-http-replay",
        RemoteRole::Viewer,
        &[],
        "http-replay-secret",
        "2026-06-21T18:00:00Z",
        "2099-06-21T18:10:00Z",
    );
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let url = format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM);

    let first = client
        .post(&url)
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "daemon.example.com",
            "client_id": "viewer-1",
            "display_name": "Viewer iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send first claim");
    assert_eq!(first.status(), StatusCode::OK);

    let replay = client
        .post(&url)
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "daemon.example.com",
            "client_id": "viewer-2",
            "display_name": "Viewer iPad",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send replay claim");

    assert_eq!(replay.status(), StatusCode::CONFLICT);
    let body = replay.json::<serde_json::Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING");
    assert!(!body.to_string().contains(code.expose()));
    let routes: Vec<_> = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert!(routes.contains(&"remote.pair.claim".to_string()));
    assert!(routes.contains(&"remote.pair.replay".to_string()));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_rate_limits_repeated_bad_code_attempts() {
    let mut state = remote_pairing_state();
    state.remote_pairing_limiter = Arc::new(Mutex::new(RemotePairingRateLimiter::new_for_tests(2)));
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let url = format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM);

    for expected_status in [
        StatusCode::BAD_REQUEST,
        StatusCode::BAD_REQUEST,
        StatusCode::TOO_MANY_REQUESTS,
    ] {
        let response = client
            .post(&url)
            .header("x-forwarded-for", "203.0.113.91")
            .json(&serde_json::json!({
                "code": "not-a-real-code",
                "domain": "daemon.example.com",
                "client_id": "ios-rate-limit",
                "display_name": "iPhone",
                "platform": "ios",
            }))
            .send()
            .await
            .expect("send bad claim");
        assert_eq!(response.status(), expected_status);
    }

    let routes: Vec<_> = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events")
        .into_iter()
        .map(|event| event.route_or_method)
        .collect();
    assert!(routes.contains(&"remote.pair.unknown".to_string()));
    assert!(routes.contains(&"remote.pair.rate_limit".to_string()));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_fails_closed_without_remote_domain_config() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .json(&serde_json::json!({
            "code": "any-code",
            "domain": "daemon.example.com",
            "client_id": "ios-unconfigured",
            "display_name": "iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send unconfigured claim");

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response.json::<serde_json::Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING_CONFIG");

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_wrong_domain_is_redacted() {
    let state = remote_pairing_state();
    let code = seed_pairing_code(
        &state,
        "pairing-http-wrong-domain",
        RemoteRole::Viewer,
        &[],
        "http-wrong-domain-secret",
        "2026-06-21T18:00:00Z",
        "2099-06-21T18:10:00Z",
    );
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "attacker.example.com",
            "client_id": "ios-wrong-domain",
            "display_name": "iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send wrong-domain claim");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = response.json::<serde_json::Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING");
    assert_eq!(
        body["error"]["message"],
        "remote pairing domain is not allowed"
    );
    let body = body.to_string();
    assert!(!body.contains("daemon.example.com"));
    assert!(!body.contains("attacker.example.com"));
    assert!(!body.contains("expected"));
    assert!(!body.contains("got"));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_redacts_store_failures() {
    let state = remote_pairing_state();
    let code = seed_pairing_code(
        &state,
        "pairing-http-store-failure",
        RemoteRole::Viewer,
        &[],
        "http-store-failure-secret",
        "2026-06-21T18:00:00Z",
        "2099-06-21T18:10:00Z",
    );
    let duplicate_token = RemoteBearerToken::generate();
    let registration = RemoteClientRegistration::new(
        "duplicate-client",
        "Existing Client",
        "ios",
        RemoteRole::Viewer,
        &[RemoteAccessScope::Read],
        duplicate_token.expose(),
        "2026-06-21T18:01:00Z",
    )
    .expect("duplicate client registration");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .register_remote_client(&registration)
        .expect("register duplicate client");
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "daemon.example.com",
            "client_id": "duplicate-client",
            "display_name": "Duplicate Client",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send duplicate-client claim");

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response.json::<serde_json::Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING_STORE");
    assert_eq!(
        body["error"]["message"],
        "remote pairing store is unavailable"
    );
    assert!(!body.to_string().contains("duplicate-client"));
    assert!(!body.to_string().contains("UNIQUE"));

    server.abort();
    let _ = server.await;
}

fn remote_pairing_state() -> crate::daemon::http::DaemonHttpState {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
    state
}

fn seed_pairing_code(
    state: &crate::daemon::http::DaemonHttpState,
    pairing_id: &str,
    role: RemoteRole,
    scopes: &[RemoteAccessScope],
    code: &str,
    created_at: &str,
    expires_at: &str,
) -> RemotePairingCode {
    let code = RemotePairingCode::from_value_for_tests(code);
    let record = RemotePairingRecord::new_for_tests(
        pairing_id, role, scopes, code.expose(), created_at, expires_at,
    )
    .expect("pairing record");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .create_remote_pairing_code(&record, &format!("audit-{pairing_id}"))
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
