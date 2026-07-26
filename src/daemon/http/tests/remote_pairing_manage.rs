//! Live-router coverage for listing and revoking pairings.
//!
//! Driven through the assembled router so the scope contract and the ownership
//! rule are both in the path. A unit test can say the query filters; only this
//! can say a broker holding `pair_manage` never sees another broker's links.

use axum::http::StatusCode;
use serde_json::Value;

use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;

use super::remote_pairing::{remote_pairing_state, serve_http};
// Shared with the mint fixture rather than copied: a second copy of the ACME
// seed drifted from the real schema the moment it was written.
use super::remote_pairing_mint::{code_from_pairing_url, seed_remote_tls_identity};

const BROKER: &str = "panel-broker";
const OTHER_BROKER: &str = "rival-broker";
const ADMIN: &str = "host-admin";
const VIEWER: &str = "panel-viewer";

#[tokio::test]
async fn a_broker_sees_the_links_it_minted_and_no_others() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let mine = mint_as(&base_url, BROKER, "4242").await;
    let theirs = mint_as(&base_url, OTHER_BROKER, "9999").await;

    let listed = list_as(&base_url, BROKER).await;
    let ids: Vec<&str> = listed
        .iter()
        .map(|entry| entry["pairing_id"].as_str().expect("pairing id"))
        .collect();

    assert!(ids.contains(&mine.as_str()), "{ids:?}");
    assert!(
        !ids.contains(&theirs.as_str()),
        "a broker must not see another broker's links: {ids:?}"
    );
    server.abort();
}

/// The daemon's own operator is who the unrestricted view is for, and a link
/// created on the host belongs to nobody the daemon authenticated, so only this
/// caller can see it at all.
#[tokio::test]
async fn an_admin_sees_every_pairing() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let mine = mint_as(&base_url, BROKER, "4242").await;
    let theirs = mint_as(&base_url, OTHER_BROKER, "9999").await;

    let listed = list_as(&base_url, ADMIN).await;
    let ids: Vec<&str> = listed
        .iter()
        .map(|entry| entry["pairing_id"].as_str().expect("pairing id"))
        .collect();

    assert!(ids.contains(&mine.as_str()), "{ids:?}");
    assert!(ids.contains(&theirs.as_str()), "{ids:?}");
    server.abort();
}

#[tokio::test]
async fn listing_without_the_scope_is_refused_before_the_handler() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::REMOTE_PAIRINGS))
        .header("x-harness-remote-client-id", VIEWER)
        .bearer_auth(remote_token(VIEWER))
        .send()
        .await
        .expect("send list request");

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    server.abort();
}

/// A link nobody claimed has no device to cut off, so revoking it has to reach
/// the link itself. If it did not, the code would stay claimable after somebody
/// deliberately withdrew it.
#[tokio::test]
async fn withdrawing_an_unclaimed_link_makes_it_unclaimable() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let minted = mint_body_as(&base_url, BROKER, "4242").await;
    let pairing_id = minted["pairing_id"].as_str().expect("pairing id").to_owned();
    let code = code_from_pairing_url(minted["pairing_url"].as_str().expect("pairing url"));

    let revoked = revoke_as(&base_url, BROKER, &pairing_id).await;
    assert_eq!(revoked.0, StatusCode::OK, "{:?}", revoked.1);
    assert_eq!(revoked.1["outcome"], "link_withdrawn");

    let claim = reqwest::Client::new()
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

    assert_eq!(claim.status(), StatusCode::GONE);
    let body = claim.json::<Value>().await.expect("json body");
    assert!(
        body["error"]["message"]
            .as_str()
            .expect("message")
            .contains("revoked"),
        "a withdrawn link must not read as expired: {body}"
    );

    // And it reads as revoked rather than pending or expired.
    let listed = list_as(&base_url, BROKER).await;
    let entry = listed
        .iter()
        .find(|entry| entry["pairing_id"] == pairing_id.as_str())
        .expect("the withdrawn link");
    assert_eq!(entry["state"], "revoked");
    server.abort();
}

/// Revoking a claimed link has to reach the device, because the credential it
/// holds is what still gets through; marking only the link would leave a live
/// device behind a row that claims it is revoked.
#[tokio::test]
async fn revoking_a_claimed_link_cuts_off_its_device() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let minted = mint_body_as(&base_url, BROKER, "4242").await;
    let pairing_id = minted["pairing_id"].as_str().expect("pairing id").to_owned();
    let code = code_from_pairing_url(minted["pairing_url"].as_str().expect("pairing url"));
    let claimed = reqwest::Client::new()
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
        .expect("send claim request")
        .json::<Value>()
        .await
        .expect("json body");
    let device_token = claimed["token"].as_str().expect("token").to_owned();

    // The device works before the revoke, so the assertion afterwards is about
    // the revoke and not about the fixture never having worked.
    let before = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::READY))
        .header("x-harness-remote-client-id", "ada-iphone")
        .bearer_auth(&device_token)
        .send()
        .await
        .expect("send ready request");
    assert_eq!(before.status(), StatusCode::OK);

    let revoked = revoke_as(&base_url, BROKER, &pairing_id).await;
    assert_eq!(revoked.0, StatusCode::OK, "{:?}", revoked.1);
    assert_eq!(revoked.1["outcome"], "device_revoked");

    let after = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::READY))
        .header("x-harness-remote-client-id", "ada-iphone")
        .bearer_auth(&device_token)
        .send()
        .await
        .expect("send ready request");
    assert_eq!(after.status(), StatusCode::UNAUTHORIZED);
    server.abort();
}

#[tokio::test]
async fn a_broker_cannot_revoke_a_link_it_did_not_mint() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let theirs = mint_as(&base_url, OTHER_BROKER, "9999").await;

    let (status, body) = revoke_as(&base_url, BROKER, &theirs).await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    server.abort();
}

/// Revoking an id that does not exist still reaches the trail. It is what
/// probing looks like, and rolling the attempt back would leave no record of
/// somebody walking the id space.
#[tokio::test]
async fn an_attempt_on_a_missing_pairing_is_still_recorded() {
    let state = manage_state();
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    revoke_as(&base_url, ADMIN, "pairing-does-not-exist").await;

    let recorded: i64 = db
        .lock()
        .expect("db lock")
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM remote_audit_events
             WHERE route_or_method = 'remote.pairing.revoke'",
            [],
            |row| row.get(0),
        )
        .expect("audit count");

    assert_eq!(recorded, 1);
    server.abort();
}

/// A pairing the caller may not see answers the same way whether or not it
/// exists, so the route cannot be used to find out which ids are real.
#[tokio::test]
async fn an_unknown_id_is_indistinguishable_from_someone_elses() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let theirs = mint_as(&base_url, OTHER_BROKER, "9999").await;

    let (others, _) = revoke_as(&base_url, BROKER, &theirs).await;
    let (absent, _) = revoke_as(&base_url, BROKER, "pairing-does-not-exist").await;

    assert_eq!(others, absent);
    server.abort();
}

#[tokio::test]
async fn revoking_records_who_did_it_and_which_pairing() {
    let state = manage_state();
    let db = state.db.get().expect("db slot").clone();
    let (base_url, server) = serve_http(state).await;

    let pairing_id = mint_as(&base_url, BROKER, "4242").await;
    revoke_as(&base_url, BROKER, &pairing_id).await;

    let db = db.lock().expect("db lock");
    let (count, client_id, metadata): (i64, String, String) = db
        .connection()
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(client_id), ''), COALESCE(MAX(metadata_json), '')
             FROM remote_audit_events WHERE route_or_method = 'remote.pairing.revoke'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("revoke audit row");

    assert_eq!(count, 1);
    assert_eq!(client_id, BROKER);
    assert!(metadata.contains(pairing_id.as_str()), "{metadata}");
    server.abort();
}

/// Revoking twice must not read as a fresh revocation, or a caller retrying
/// cannot tell whether it was the one that cut the device off.
#[tokio::test]
async fn a_second_revoke_reports_that_it_was_already_done() {
    let state = manage_state();
    let (base_url, server) = serve_http(state).await;

    let pairing_id = mint_as(&base_url, BROKER, "4242").await;
    revoke_as(&base_url, BROKER, &pairing_id).await;

    let first = revoke_as(&base_url, BROKER, &pairing_id).await.1;
    let (status, body) = revoke_as(&base_url, BROKER, &pairing_id).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["outcome"], "already_revoked");
    // The moment it was really cut off, not the moment this request arrived.
    // Reporting `now` would let a retry read as the revocation that did it.
    assert_eq!(body["revoked_at"], first["revoked_at"], "{body}");
    server.abort();
}

async fn list_as(base_url: &str, client_id: &str) -> Vec<Value> {
    let response = reqwest::Client::new()
        .get(format!("{base_url}{}", http_paths::REMOTE_PAIRINGS))
        .header("x-harness-remote-client-id", client_id)
        .bearer_auth(remote_token(client_id))
        .send()
        .await
        .expect("send list request");
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.json::<Value>().await.expect("json body");
    body["pairings"]
        .as_array()
        .expect("pairings array")
        .clone()
}

async fn revoke_as(base_url: &str, client_id: &str, pairing_id: &str) -> (StatusCode, Value) {
    let response = reqwest::Client::new()
        .post(format!(
            "{base_url}/v1/remote/pairings/{pairing_id}/revoke"
        ))
        .header("x-harness-remote-client-id", client_id)
        .bearer_auth(remote_token(client_id))
        .send()
        .await
        .expect("send revoke request");
    let status = response.status();
    let body = response.json::<Value>().await.expect("json body");
    (status, body)
}

async fn mint_body_as(base_url: &str, client_id: &str, subject_id: &str) -> Value {
    reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::REMOTE_PAIR_MINT))
        .header("x-harness-remote-client-id", client_id)
        .bearer_auth(remote_token(client_id))
        .json(&serde_json::json!({
            "role": "viewer",
            "subject": {
                "provider": "github",
                "subject_id": subject_id,
                "display_name": "Ada Lovelace",
            },
        }))
        .send()
        .await
        .expect("send mint request")
        .json::<Value>()
        .await
        .expect("json body")
}

async fn mint_as(base_url: &str, client_id: &str, subject_id: &str) -> String {
    mint_body_as(base_url, client_id, subject_id).await["pairing_id"]
        .as_str()
        .expect("pairing id")
        .to_owned()
}

fn remote_token(client_id: &str) -> String {
    format!("token-{client_id}-0123456789abcdef")
}

fn manage_state() -> DaemonHttpState {
    let state = remote_pairing_state();
    {
        let db = state.db.get().expect("db slot").lock().expect("db lock");
        seed_remote_tls_identity(&db);
        for (client_id, role) in [
            (BROKER, RemoteRole::PairingBroker),
            (OTHER_BROKER, RemoteRole::PairingBroker),
            (ADMIN, RemoteRole::Admin),
            (VIEWER, RemoteRole::Viewer),
        ] {
            let registration = RemoteClientRegistration::new_for_tests(
                client_id,
                "Manage Fixture",
                "test",
                role,
                &[] as &[RemoteAccessScope],
                remote_token(client_id).as_str(),
                "2026-07-25T08:00:00Z",
            )
            .expect("manage fixture registration");
            db.register_remote_client(&registration)
                .expect("register manage fixture client");
        }
    }
    state
}
