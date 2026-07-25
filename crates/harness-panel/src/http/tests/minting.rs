//! The mint call itself, against a stub standing in for the daemon.
//!
//! The other pair-link tests stop at the panel's own checks. These go through
//! them: a credential is stored, so `DaemonClient::mint` really runs and the
//! request body, the two auth headers, and the response parsing are all
//! exercised. Without this, a field renamed on either side of the wire would
//! ship green, because the daemon's types live in a crate this one is barred
//! from depending on.

use std::sync::{Arc, Mutex};

use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use chrono::{Duration, Utc};
use serde_json::Value;
use tokio::net::TcpListener;

use super::Harness;
use crate::daemon_client::DaemonCredential;
use crate::store::pair_links::PairLinkRecord;

/// What the stub saw, so a test can assert on the request the panel sent.
#[derive(Debug, Default)]
struct Seen {
    body: Option<Value>,
    client_id: Option<String>,
    authorization: Option<String>,
}

async fn stub_daemon(seen: Arc<Mutex<Seen>>) -> String {
    async fn mint(
        State(seen): State<Arc<Mutex<Seen>>>,
        headers: HeaderMap,
        Json(body): Json<Value>,
    ) -> Json<Value> {
        let header = |name: &str| {
            headers
                .get(name)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned)
        };
        {
            let mut seen = seen.lock().expect("stub lock");
            seen.body = Some(body);
            seen.client_id = header("x-harness-remote-client-id");
            seen.authorization = header("authorization");
        }
        Json(serde_json::json!({
            "pairing_id": "pair-1",
            "role": "operator",
            "scopes": ["read", "write"],
            "created_at": "2026-07-25T10:00:00Z",
            "expires_at": "2026-07-25T10:10:00Z",
            "ttl_seconds": 600,
            "endpoint": "https://harness.example.com",
            "server_spki_sha256": "sha256/AAAA",
            "pairing_url": "harness://pair?payload=abc",
            "subject": {"provider": "github", "subject_id": "4242", "display_name": "Ada"}
        }))
    }

    let app = Router::new()
        .route("/v1/remote/pair/mint", post(mint))
        .with_state(seen);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let address = listener.local_addr().expect("local address");
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    format!("http://127.0.0.1:{}", address.port())
}

/// An approved account, a stored credential, and a daemon that answers.
async fn ready(seen: Arc<Mutex<Seen>>) -> (Harness, String) {
    let endpoint = stub_daemon(seen).await;
    let harness = Harness::with_daemon("ada", &endpoint).await;
    let owner = harness.sign_in("ada").await;
    let owner_id = harness.account_id("ada").await;
    harness
        .post(
            &format!("/panel/api/accounts/{owner_id}/approve"),
            Some(&owner),
        )
        .await;
    harness
        .state
        .store
        .store_daemon_credential(
            &DaemonCredential {
                client_id: "panel-1".to_owned(),
                token: "broker-token".to_owned(),
                role: "pairing_broker".to_owned(),
            },
            Utc::now(),
        )
        .await
        .expect("credential");
    (harness, owner)
}

#[tokio::test]
async fn the_link_the_daemon_minted_reaches_the_caller() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body.contains("harness://pair?payload=abc"), "{body}");
    assert!(body.contains("\"pairing_id\":\"pair-1\""), "{body}");
    assert!(body.contains("\"expires_at\""), "{body}");
}

/// The daemon reads the panel's identity from a header and its token from
/// another. A rename on either side would leave the panel unauthenticated, and
/// nothing else in the suite would notice.
#[tokio::test]
async fn the_stored_credential_is_replayed_on_both_headers() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    harness.post("/panel/api/pair-links", Some(&owner)).await;

    let seen = seen.lock().expect("stub lock");
    assert_eq!(seen.client_id.as_deref(), Some("panel-1"));
    assert_eq!(seen.authorization.as_deref(), Some("Bearer broker-token"));
}

/// The role, the lifetime, and the subject all come from the panel, never from
/// the request, and the subject names the immutable GitHub id rather than the
/// login.
#[tokio::test]
async fn the_request_carries_the_panels_own_terms() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    harness.post("/panel/api/pair-links", Some(&owner)).await;

    let seen = seen.lock().expect("stub lock");
    let body = seen.body.as_ref().expect("a mint request");
    assert_eq!(body["role"], "operator");
    assert_eq!(body["ttl_seconds"], 600);
    assert_eq!(body["subject"]["provider"], "github");
    assert_eq!(body["subject"]["subject_id"], "ada");
    assert!(
        body.get("scopes").is_none(),
        "scopes are the role's: {body}"
    );
}

/// The response carries a one-time code, so a cache between the daemon and the
/// browser must never keep it.
#[tokio::test]
async fn the_minted_link_is_never_cacheable() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    let cache_control = harness
        .post_response("/panel/api/pair-links", Some(&owner))
        .await;

    assert_eq!(cache_control.as_deref(), Some("no-store"));
}

/// The link is live on the daemon whether or not the panel wrote it down, so
/// the record is kept as metadata and the caller still gets the link.
#[tokio::test]
async fn minting_records_the_link_as_metadata_only() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;
    let owner_id = harness.account_id("ada").await;

    harness.post("/panel/api/pair-links", Some(&owner)).await;

    let recorded = harness
        .state
        .store
        .pair_links_for_account(&owner_id)
        .await
        .expect("records");
    assert_eq!(recorded.len(), 1);
    assert_eq!(recorded[0].id, "pair-1");
    assert_eq!(recorded[0].role, "operator");
}

/// A revoke cannot reach a link already minted, so the cap is the only thing
/// bounding how many an approved account can hold at once.
#[tokio::test]
async fn an_account_cannot_hold_more_live_links_than_the_cap() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    // The stub answers with the same pairing id every time, so each attempt
    // after the first replaces nothing; drive the cap with distinct rows.
    for index in 0..5 {
        harness
            .state
            .store
            .record_pair_link(&PairLinkRecord {
                id: format!("seed-{index}"),
                account_id: harness.account_id("ada").await,
                role: "operator".to_owned(),
                created_at: Utc::now(),
                expires_at: Utc::now() + Duration::hours(1),
            })
            .await
            .expect("seed");
    }

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(body.contains("unexpired pairing links"), "{body}");
}
