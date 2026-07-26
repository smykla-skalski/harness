use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use axum::body::Body;
use axum::http::{Method, StatusCode, header};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tower::ServiceExt;

use super::{Harness, MintPause, Seen, ready, router, session_cookie_name};
use crate::http::PanelState;

#[tokio::test]
async fn another_origin_cannot_mint_a_pairing_link() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;

    let (status, body) = harness
        .post_from_origin(
            "/panel/api/pair-links",
            Some(&owner),
            Some("https://attacker.example.com"),
        )
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(seen.lock().expect("stub lock").minted, 0);
}

#[tokio::test]
async fn an_ambiguous_mint_answer_keeps_the_reserved_slot() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;
    seen.lock().expect("stub lock").malformed_answer = true;

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    let records = harness
        .state
        .store
        .pair_links_for_account(&harness.account_id("ada").await)
        .await
        .expect("records");
    assert_eq!(records.len(), 1, "{records:?}");
    assert!(records[0].id.starts_with("reservation:"), "{records:?}");
}

#[tokio::test]
async fn a_confirmed_daemon_refusal_releases_the_reserved_slot() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;
    seen.lock().expect("stub lock").refusal_status = Some(StatusCode::SERVICE_UNAVAILABLE);

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    let account_id = harness.account_id("ada").await;
    let records = harness
        .state
        .store
        .pair_links_for_account(&account_id)
        .await
        .expect("records");
    assert!(records.is_empty(), "{records:?}");

    seen.lock().expect("stub lock").refusal_status = None;
    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revoking_waits_for_an_in_flight_mint() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;
    let pause = Arc::new(MintPause::new());
    seen.lock().expect("stub lock").pause = Some(Arc::clone(&pause));

    let mint = post_in_task(
        harness.state.clone(),
        "/panel/api/pair-links".to_owned(),
        owner.clone(),
    );
    pause.started.wait().await;

    let account_id = harness.account_id("ada").await;
    let mut revoke = post_in_task(
        harness.state.clone(),
        format!("/panel/api/accounts/{account_id}/revoke"),
        owner.clone(),
    );
    assert!(
        timeout(StdDuration::from_millis(100), &mut revoke)
            .await
            .is_err(),
        "revoke returned while the daemon was still minting"
    );

    pause.release.wait().await;
    assert_eq!(mint.await.expect("mint task"), StatusCode::OK);
    assert_eq!(revoke.await.expect("revoke task"), StatusCode::OK);
    let (status, _) = harness.post("/panel/api/pair-links", Some(&owner)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

fn post_in_task(state: PanelState, path: String, session: String) -> JoinHandle<StatusCode> {
    tokio::spawn(async move {
        let cookie = format!("{}={session}", session_cookie_name(&state));
        let origin = state.config.public_origin.clone();
        let request = Harness::request()
            .method(Method::POST)
            .uri(path)
            .header(header::COOKIE, cookie)
            .header(header::ORIGIN, origin)
            .body(Body::empty())
            .expect("request");
        router(state)
            .oneshot(request)
            .await
            .expect("response")
            .status()
    })
}
