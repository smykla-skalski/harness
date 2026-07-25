//! Starting, finishing, and ending a sign-in, at the router.

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use tower::ServiceExt;

use super::super::router;
use super::super::session::SESSION_COOKIE;
use super::{BODY_LIMIT, Harness, pending_states};
use crate::config::DEFAULT_GITHUB_AUTHORIZE_URL;

#[tokio::test]
async fn signing_out_clears_the_session_on_the_server() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/panel/auth/signout")
                .header(header::COOKIE, format!("{SESSION_COOKIE}={token}"))
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
        .find(|value| value.starts_with(SESSION_COOKIE))
        .expect("the session cookie is expired");
    assert!(expiry.contains("Max-Age=0"), "{expiry}");
    // The cookie only asks the browser to cooperate; the session has to be gone.
    assert_eq!(
        harness.get("/panel/api/me", Some(&token)).await.0,
        StatusCode::UNAUTHORIZED
    );
}

/// Signing out is a state change, so a plain link or an image tag must not be
/// able to trigger it.
#[tokio::test]
async fn signing_out_is_not_a_get() {
    let harness = Harness::new("ada").await;

    let (status, _) = harness.get("/panel/auth/signout", None).await;

    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
}

/// A `Secure` cookie is dropped by the browser over plain HTTP, so the flag has
/// to follow the public origin rather than be pinned on.
#[tokio::test]
async fn the_sign_in_cookie_is_scoped_to_the_panel() {
    let harness = Harness::new("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri("/panel/auth/github/start")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    let cookie = response
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|value| value.to_str().ok())
        .expect("a sign-in cookie");

    assert!(cookie.contains("HttpOnly"), "{cookie}");
    assert!(cookie.contains("SameSite=Lax"), "{cookie}");
    assert!(cookie.contains("Path=/panel"), "{cookie}");
    assert!(cookie.contains("Secure"), "{cookie}");
}

/// The browser has to be sent to GitHub carrying the same state the panel just
/// recorded, or the callback can never match it.
#[tokio::test]
async fn starting_a_sign_in_redirects_to_github_with_the_recorded_state() {
    let harness = Harness::new("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri("/panel/auth/github/start")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    let location = response
        .headers()
        .get(header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("a redirect")
        .to_owned();
    let cookie = response
        .headers()
        .get(header::SET_COOKIE)
        .and_then(|value| value.to_str().ok())
        .expect("a sign-in cookie")
        .to_owned();
    let state = cookie
        .split(';')
        .next()
        .and_then(|pair| pair.split_once('='))
        .map(|(_, value)| value.to_owned())
        .expect("the cookie carries the state");

    assert!(
        location.starts_with(DEFAULT_GITHUB_AUTHORIZE_URL),
        "{location}"
    );
    assert!(location.contains(&format!("state={state}")), "{location}");
    assert!(
        location.contains("redirect_uri=https%3A%2F%2Fharness.example.com%2Fpanel%2Fauth"),
        "{location}"
    );
}

/// Two tabs means two sign-ins in flight from one browser, and whichever
/// consent screen the person finishes first has to be accepted. The store-level
/// test of this property cannot see the HTTP layer breaking it, which is
/// exactly what a single-valued cookie did.
#[tokio::test]
async fn two_tabs_can_both_finish_a_sign_in() {
    let harness = Harness::with_unreachable_github("ada").await;

    let first = harness.start_sign_in(None).await;
    // The second tab starts while the first is still on GitHub's consent
    // screen, so it carries the cookie the first tab was issued.
    let second = harness.start_sign_in(Some(&first.cookie)).await;

    let pending = pending_states(&second.cookie);
    assert!(
        pending.contains(&first.state) && pending.contains(&second.state),
        "both tabs must stay pending, got {pending:?}"
    );

    // The person finishes the older tab first, presenting the cookie the
    // browser now holds. It must get past state validation; the sign-in then
    // fails at the unreachable token endpoint, which is a different failure.
    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/panel/auth/github/callback?code=abc&state={}",
                    first.state
                ))
                .header(header::COOKIE, &second.cookie)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    let remaining = response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with("harness_panel_signin="))
        .and_then(|value| value.split(';').next())
        .expect("a rewritten sign-in cookie")
        .to_owned();
    let body = String::from_utf8_lossy(
        &to_bytes(response.into_body(), BODY_LIMIT)
            .await
            .expect("body"),
    )
    .into_owned();

    assert!(
        !body.contains("does not match"),
        "the first tab was refused for having been overtaken: {body}"
    );
    // Spending the first tab's state leaves the second tab's alone.
    let still_pending = pending_states(&remaining);
    assert!(!still_pending.contains(&first.state), "{still_pending:?}");
    assert!(still_pending.contains(&second.state), "{still_pending:?}");
}

/// A callback that arrives without the cookie is one this browser never
/// started, which is what a login-CSRF attempt looks like.
#[tokio::test]
async fn a_callback_without_the_sign_in_cookie_is_refused() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness
        .get("/panel/auth/github/callback?code=abc&state=whatever", None)
        .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("\"code\":\"sign_in\""), "{body}");
}

/// A refused callback must not leave the browser holding the state value it
/// just refused. The cleared cookie only reaches the browser if the failure
/// response carries it, which an early return would silently skip.
#[tokio::test]
async fn a_refused_callback_still_clears_the_sign_in_cookie() {
    let harness = Harness::new("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri("/panel/auth/github/callback?code=abc&state=whatever")
                .header(header::COOKIE, "harness_panel_signin=whatever")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let cleared = response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with("harness_panel_signin"))
        .expect("the sign-in cookie is expired on the failure response");
    assert!(cleared.contains("Max-Age=0"), "{cleared}");
}

#[tokio::test]
async fn a_callback_github_refused_reports_the_reason() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness
        .get(
            "/panel/auth/github/callback?error=access_denied&error_description=The+user+said+no",
            None,
        )
        .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("The user said no"), "{body}");
}
