use std::sync::{Arc, Mutex};

use axum::http::StatusCode;

use crate::daemon::protocol::http_paths;
use crate::daemon::remote::RemoteRole;
use crate::daemon::remote_pairing::RemotePairingRateLimiter;

use super::remote_pairing::{remote_pairing_state, seed_pairing_code, serve_http};

#[tokio::test]
async fn remote_pair_claim_replay_preserves_request_provenance() {
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
        .header("x-request-id", "pairing-http-replay-request")
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
    let events = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events");
    let replay_event = events
        .iter()
        .find(|event| event.route_or_method == "remote.pair.replay")
        .expect("replay audit event");
    assert_eq!(
        replay_event.request_id.as_deref(),
        Some("pairing-http-replay-request")
    );
    assert_eq!(replay_event.client_id.as_deref(), Some("viewer-2"));
    assert_eq!(replay_event.remote_addr.as_deref(), Some("127.0.0.1"));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_rate_limit_preserves_request_provenance() {
    let mut state = remote_pairing_state();
    state.remote_pairing_limiter = Arc::new(Mutex::new(RemotePairingRateLimiter::new_for_tests(2)));
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let url = format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM);

    for (index, expected_status) in [
        StatusCode::BAD_REQUEST,
        StatusCode::BAD_REQUEST,
        StatusCode::TOO_MANY_REQUESTS,
    ]
    .into_iter()
    .enumerate()
    {
        let attempt = index + 1;
        let response = client
            .post(&url)
            .header(
                "x-request-id",
                format!("pairing-rate-limit-request-{attempt}"),
            )
            .json(&serde_json::json!({
                "code": format!("not-a-real-code-{attempt}"),
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

    let events = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events");
    let rate_limit_event = events
        .iter()
        .find(|event| event.route_or_method == "remote.pair.rate_limit")
        .expect("rate-limit audit event");
    assert_eq!(
        rate_limit_event.request_id.as_deref(),
        Some("pairing-rate-limit-request-3")
    );
    assert_eq!(
        rate_limit_event.client_id.as_deref(),
        Some("ios-rate-limit")
    );
    assert_eq!(rate_limit_event.remote_addr.as_deref(), Some("127.0.0.1"));
    assert!(
        events
            .iter()
            .any(|event| event.route_or_method == "remote.pair.unknown")
    );

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_bounds_persisted_request_id() {
    let state = remote_pairing_state();
    let code = seed_pairing_code(
        &state,
        "pairing-http-bounded-request",
        RemoteRole::Viewer,
        &[],
        "http-bounded-request-secret",
        "2026-06-21T18:00:00Z",
        "2099-06-21T18:10:00Z",
    );
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;
    let request_id = "r".repeat(300);

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .header("x-request-id", request_id)
        .json(&serde_json::json!({
            "code": code.expose(),
            "domain": "daemon.example.com",
            "client_id": "bounded-request-viewer",
            "display_name": "Viewer iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send pairing claim");

    assert_eq!(response.status(), StatusCode::OK);
    let events = db
        .lock()
        .expect("db lock")
        .load_remote_audit_events(10)
        .expect("audit events");
    let claim_event = events
        .iter()
        .find(|event| event.route_or_method == "remote.pair.claim")
        .expect("claim audit event");
    let stored_request_id = claim_event.request_id.as_deref().expect("request id");
    assert_eq!(stored_request_id.len(), 256);
    assert!(stored_request_id.ends_with("..."));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn remote_pair_claim_rate_limit_fails_closed_without_audit_storage() {
    let mut state = remote_pairing_state();
    state.remote_pairing_limiter = Arc::new(Mutex::new(RemotePairingRateLimiter::new_for_tests(1)));
    state
        .remote_pairing_limiter
        .lock()
        .expect("pairing limiter lock")
        .record_attempt("127.0.0.1", "primed-code-fingerprint")
        .expect("prime pairing limiter");
    state
        .db
        .get()
        .expect("db slot")
        .lock()
        .expect("db lock")
        .connection()
        .execute("DROP TABLE remote_audit_events", [])
        .expect("drop remote audit table");
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .header("x-request-id", "pairing-rate-limit-no-audit")
        .json(&serde_json::json!({
            "code": "rate-limited-code",
            "domain": "daemon.example.com",
            "client_id": "rate-limited-client",
            "display_name": "Rate Limited Client",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send rate-limited claim without audit storage");

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIRING_STORE");
    assert_eq!(
        body["error"]["message"],
        "remote pairing store is unavailable"
    );
    assert!(!body.to_string().contains("rate-limited-client"));

    server.abort();
    let _ = server.await;
}
