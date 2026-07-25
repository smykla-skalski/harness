//! Live-router coverage for `POST /v1/remote/pair/mint`.
//!
//! These drive the assembled daemon router so the auth middleware, the scope
//! contract, and the handler are all in the path. A unit test can say the
//! handler refuses a role; only this can say an unauthorized caller never
//! reaches the handler at all.

use axum::http::StatusCode;
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};
use serde_json::Value;

use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::remote_pairing::{remote_pairing_state, serve_http};

const BROKER_CLIENT_ID: &str = "panel-broker";
const VIEWER_CLIENT_ID: &str = "panel-viewer";

#[tokio::test]
async fn a_broker_mints_a_link_that_records_who_it_was_for() {
    let state = mint_state();
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    let response = mint_request(&base_url, BROKER_CLIENT_ID)
        .json(&serde_json::json!({
            "role": "operator",
            "ttl_seconds": 600,
            "subject": {
                "provider": "github",
                "subject_id": "4242",
                "display_name": "Ada Lovelace",
            },
        }))
        .send()
        .await
        .expect("send mint request");

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.json::<Value>().await.expect("json body");
    assert_eq!(body["role"], "operator");
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
    assert_eq!(body["subject"]["subject_id"], "4242");
    assert_eq!(body["ttl_seconds"], 600);
    assert!(
        body["pairing_url"]
            .as_str()
            .expect("pairing url")
            .starts_with("harness://pair?payload="),
        "{body}"
    );
    // The link carries the code inside its payload; a second plaintext copy
    // would be one more place for it to be logged.
    assert!(body.get("code").is_none(), "{body}");

    let pairing_id = body["pairing_id"].as_str().expect("pairing id");
    let db = db.lock().expect("db lock");
    let metadata: String = db
        .connection()
        .query_row(
            "SELECT metadata_json FROM remote_pairing_codes WHERE pairing_id = ?1",
            [pairing_id],
            |row| row.get(0),
        )
        .expect("stored pairing metadata");
    assert!(metadata.contains("\"subject_id\":\"4242\""), "{metadata}");
    let (minted_events, audit_detail): (i64, String) = db
        .connection()
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(error_detail), '') FROM remote_audit_events
             WHERE route_or_method = 'remote.pair.mint'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("mint audit count");
    assert_eq!(minted_events, 1);
    assert!(audit_detail.contains("github:4242"), "{audit_detail}");
    assert!(audit_detail.contains(pairing_id), "{audit_detail}");

    server.abort();
}

#[tokio::test]
async fn minting_without_credentials_is_refused_before_the_handler() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_MINT))
        .json(&mint_body())
        .send()
        .await
        .expect("send mint request");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    server.abort();
}

#[tokio::test]
async fn a_client_without_the_scope_cannot_mint() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let response = mint_request(&base_url, VIEWER_CLIENT_ID)
        .json(&mint_body())
        .send()
        .await
        .expect("send mint request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    server.abort();
}

/// A broker holds `pair_mint` and nothing else, so the rest of the API stays
/// shut even though it is a fully authenticated client.
#[tokio::test]
async fn a_broker_reaches_nothing_but_the_mint_route() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::READY))
        .header("x-harness-remote-client-id", BROKER_CLIENT_ID)
        .bearer_auth(remote_token(BROKER_CLIENT_ID))
        .send()
        .await
        .expect("send ready request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    server.abort();
}

#[tokio::test]
async fn a_broker_cannot_mint_another_broker() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let response = mint_request(&base_url, BROKER_CLIENT_ID)
        .json(&serde_json::json!({
            "role": "pairing_broker",
            "subject": subject(),
        }))
        .send()
        .await
        .expect("send mint request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = response.json::<Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIR_MINT_ROLE");
    server.abort();
}

#[tokio::test]
async fn a_scope_the_role_does_not_carry_is_refused() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let response = mint_request(&base_url, BROKER_CLIENT_ID)
        .json(&serde_json::json!({
            "role": "viewer",
            "scopes": ["admin"],
            "subject": subject(),
        }))
        .send()
        .await
        .expect("send mint request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body = response.json::<Value>().await.expect("json body");
    assert_eq!(body["error"]["code"], "REMOTE_PAIR_MINT_SCOPE");
    server.abort();
}

#[tokio::test]
async fn a_malformed_subject_or_ttl_is_refused() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    for body in [
        serde_json::json!({
            "role": "viewer",
            "subject": {"provider": "github", "subject_id": "", "display_name": "Ada"},
        }),
        serde_json::json!({"role": "viewer", "ttl_seconds": 0, "subject": subject()}),
        serde_json::json!({"role": "viewer", "ttl_seconds": 86_401, "subject": subject()}),
        serde_json::json!({"role": "wizard", "subject": subject()}),
        serde_json::json!({"role": "viewer", "scopes": ["telepathy"], "subject": subject()}),
    ] {
        let response = mint_request(&base_url, BROKER_CLIENT_ID)
            .json(&body)
            .send()
            .await
            .expect("send mint request");

        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{body}");
    }

    server.abort();
}

/// The mint route is the only pairing route that is not public, so the claim
/// route must keep working without credentials while it exists.
#[tokio::test]
async fn a_minted_link_is_claimable_by_its_recipient() {
    let state = mint_state();
    let (base_url, server) = serve_http(state).await;

    let minted = mint_request(&base_url, BROKER_CLIENT_ID)
        .json(&serde_json::json!({"role": "viewer", "subject": subject()}))
        .send()
        .await
        .expect("send mint request")
        .json::<Value>()
        .await
        .expect("json body");
    let code = code_from_pairing_url(minted["pairing_url"].as_str().expect("pairing url"));

    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_CLAIM))
        .json(&serde_json::json!({
            "code": code,
            "domain": "daemon.example.com",
            "client_id": "ada-iphone",
            "display_name": "Ada iPhone",
            "platform": "ios",
        }))
        .send()
        .await
        .expect("send claim request");

    assert_eq!(response.status(), StatusCode::OK);
    let claimed = response.json::<Value>().await.expect("json body");
    assert_eq!(claimed["client_id"], "ada-iphone");
    assert_eq!(claimed["role"], "viewer");
    assert!(!claimed["token"].as_str().expect("token").is_empty());
    server.abort();
}

fn code_from_pairing_url(pairing_url: &str) -> String {
    use base64::Engine as _;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    let payload = pairing_url
        .strip_prefix("harness://pair?payload=")
        .expect("pairing url payload");
    let decoded = URL_SAFE_NO_PAD.decode(payload).expect("decode payload");
    let payload = serde_json::from_slice::<Value>(&decoded).expect("payload json");
    payload["code"].as_str().expect("payload code").to_owned()
}

fn mint_request(base_url: &str, client_id: &str) -> reqwest::RequestBuilder {
    reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_MINT))
        .header("x-harness-remote-client-id", client_id)
        .bearer_auth(remote_token(client_id))
}

fn mint_body() -> Value {
    serde_json::json!({"role": "viewer", "subject": subject()})
}

fn subject() -> Value {
    serde_json::json!({
        "provider": "github",
        "subject_id": "4242",
        "display_name": "Ada Lovelace",
    })
}

fn remote_token(client_id: &str) -> String {
    format!("token-{client_id}-0123456789abcdef")
}

fn mint_state() -> DaemonHttpState {
    let state = remote_pairing_state();
    {
        let db = state.db.get().expect("db slot").lock().expect("db lock");
        seed_remote_tls_identity(&db);
        for (client_id, role) in [
            (BROKER_CLIENT_ID, RemoteRole::PairingBroker),
            (VIEWER_CLIENT_ID, RemoteRole::Viewer),
        ] {
            let registration = RemoteClientRegistration::new_for_tests(
                client_id,
                "Mint Fixture",
                "test",
                role,
                &[] as &[RemoteAccessScope],
                remote_token(client_id).as_str(),
                "2026-07-25T08:00:00Z",
            )
            .expect("mint fixture registration");
            db.register_remote_client(&registration)
                .expect("register mint fixture client");
        }
    }
    state
}

/// The invitation is built from persisted ACME state, and its SPKI pin is
/// computed by parsing the stored leaf, so the fixture needs a real
/// certificate rather than placeholder PEM text.
fn seed_remote_tls_identity(db: &DaemonDb) {
    let key = KeyPair::generate().expect("generate fixture key");
    let mut params = CertificateParams::new(vec!["daemon.example.com".to_owned()])
        .expect("fixture certificate params");
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, "daemon.example.com");
    let certificate = params.self_signed(&key).expect("self-sign fixture cert");

    db.connection()
        .execute(
            r#"UPDATE remote_acme_state
             SET domain = 'daemon.example.com',
                 host = '0.0.0.0',
                 https_port = 443,
                 http_port = 80,
                 acme_email = 'ops@example.com',
                 acme_challenge = 'tls-alpn',
                 acme_dns_provider = NULL,
                 account_id = 'acct-mint',
                 account_credentials_json = '{"id":"acct-mint","key_pkcs8":"k"}',
                 certificate_pem = ?1,
                 private_key_pem = ?2,
                 certificate_fingerprint = 'fixture-fp',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-07-25T08:00:00Z'
             WHERE singleton = 1"#,
            rusqlite::params![certificate.pem(), key.serialize_pem()],
        )
        .expect("seed remote tls identity");
}
