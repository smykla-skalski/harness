//! Starting, finishing, and ending a sign-in, at the router.

use std::path::Path;

use axum::body::{Body, to_bytes};
use axum::http::{StatusCode, header};
use chrono::{Duration, Utc};
use tower::ServiceExt;

mod callback;

use super::super::session::{SESSION_COOKIE_PREFIX, session_cookie_name};
use super::super::{PanelState, router};
use super::{BODY_LIMIT, Harness};
use crate::store::Store;
use crate::store::accounts::AccountIdentity;

#[tokio::test]
async fn signing_out_clears_the_session_on_the_server() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;
    let session_cookie = session_cookie_name(&harness.state);

    let response = router(harness.state.clone())
        .oneshot(
            Harness::request()
                .method("POST")
                .uri("/panel/auth/signout")
                .header(header::ORIGIN, harness.state.config.public_origin.as_str())
                .header(header::COOKIE, format!("{session_cookie}={token}"))
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let expiry = response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with(&session_cookie))
        .expect("the session cookie is expired");
    assert!(expiry.contains("Max-Age=0"), "{expiry}");
    // The cookie only asks the browser to cooperate; the session has to be gone.
    assert_eq!(
        harness.get("/panel/api/me", Some(&token)).await.0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn signing_out_without_a_session_sets_no_cookie() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;
    let response = router(harness.state.clone())
        .oneshot(
            Harness::request()
                .method("POST")
                .uri("/panel/auth/signout")
                .header(header::ORIGIN, harness.state.config.public_origin.as_str())
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(
        response.headers().get(header::SET_COOKIE).is_none(),
        "a request with no session must not carry an expiry back"
    );
    // And the session it never presented is untouched.
    assert_eq!(
        harness.get("/panel/api/me", Some(&token)).await.0,
        StatusCode::OK
    );
}

#[tokio::test]
async fn nested_mount_reconfiguration_keeps_each_session_cookie_independent() {
    let directory = tempfile::tempdir().expect("temp dir");
    let store = Store::open_in_memory().await.expect("store");
    let old_state = panel_state_at(directory.path(), "/panel", store.clone());
    let new_state = panel_state_at(directory.path(), "/panel/admin", store.clone());
    let old_identity = identity("old-account", "100");
    let new_identity = identity("new-account", "200");
    let (_, old_token) = store
        .complete_sign_in(&old_identity, false, Duration::hours(12), Utc::now())
        .await
        .expect("old session");
    let (_, new_token) = store
        .complete_sign_in(&new_identity, false, Duration::hours(12), Utc::now())
        .await
        .expect("new session");
    let old_cookie = session_cookie_name(&old_state);
    let new_cookie = session_cookie_name(&new_state);
    assert!(old_cookie.starts_with(SESSION_COOKIE_PREFIX));
    assert_ne!(old_cookie, new_cookie);
    let browser_cookies = format!(
        "{new_cookie}={}; {old_cookie}={}",
        new_token.expose(),
        old_token.expose()
    );
    let viewer = router(new_state.clone())
        .oneshot(
            Harness::request()
                .uri("/panel/admin/api/me")
                .header(header::COOKIE, &browser_cookies)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    let viewer_body = String::from_utf8_lossy(
        &to_bytes(viewer.into_body(), BODY_LIMIT)
            .await
            .expect("body"),
    )
    .into_owned();
    assert!(
        viewer_body.contains("\"login\":\"new-account\""),
        "{viewer_body}"
    );
    assert!(
        !viewer_body.contains("\"login\":\"old-account\""),
        "{viewer_body}"
    );
    let signout = router(new_state.clone())
        .oneshot(
            Harness::request()
                .method("POST")
                .uri("/panel/admin/auth/signout")
                .header(header::ORIGIN, new_state.config.public_origin.as_str())
                .header(header::COOKIE, browser_cookies)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(signout.status(), StatusCode::NO_CONTENT);
    let expired = signout
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with(&new_cookie))
        .expect("current deployment cookie expiry");
    assert!(expired.contains("Max-Age=0"), "{expired}");
    assert!(
        store
            .session_for_token(old_token.expose(), Utc::now())
            .await
            .expect("old session")
            .is_some()
    );
    assert!(
        store
            .session_for_token(new_token.expose(), Utc::now())
            .await
            .expect("new session")
            .is_none()
    );
}

fn panel_state_at(directory: &Path, base_path: &str, store: Store) -> PanelState {
    let mut raw = super::args(directory, "owner");
    raw.base_path = base_path.to_owned();
    PanelState::new(raw.resolve().expect("config"), store).expect("panel state")
}

fn identity(login: &str, subject_id: &str) -> AccountIdentity {
    AccountIdentity {
        provider: "github:https://api.github.com".to_owned(),
        subject_id: subject_id.to_owned(),
        login: login.to_owned(),
        display_name: login.to_owned(),
        avatar_url: None,
    }
}

/// `SameSite=Lax` cookies are still sent between different origins on the same
/// site, so the sign-out endpoint must verify the browser-supplied origin.
#[tokio::test]
async fn signing_out_from_a_missing_or_different_origin_is_refused() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;
    let session_cookie = session_cookie_name(&harness.state);

    for origin in [
        None,
        Some("https://attacker.example.com"),
        Some("https://harness.example.com/"),
    ] {
        let mut request = Harness::request()
            .method("POST")
            .uri("/panel/auth/signout")
            .header(header::COOKIE, format!("{session_cookie}={token}"));
        if let Some(origin) = origin {
            request = request.header(header::ORIGIN, origin);
        }
        let response = router(harness.state.clone())
            .oneshot(request.body(Body::empty()).expect("request"))
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(response.headers().get(header::SET_COOKIE).is_none());
        assert_eq!(
            harness.get("/panel/api/me", Some(&token)).await.0,
            StatusCode::OK
        );
    }
}

/// Signing out is a state change, so a plain link or an image tag must not be
/// able to trigger it.
#[tokio::test]
async fn signing_out_is_not_a_get() {
    let harness = Harness::new("ada").await;

    let (status, _) = harness.get("/panel/auth/signout", None).await;

    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
}
