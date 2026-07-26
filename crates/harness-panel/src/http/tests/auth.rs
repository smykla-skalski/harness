//! Starting, finishing, and ending a sign-in, at the router.

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use tower::ServiceExt;

use super::super::router;
use super::super::session::{SESSION_COOKIE, sign_in_cookie_name};
use super::{BODY_LIMIT, Harness};
use crate::config::DEFAULT_GITHUB_AUTHORIZE_URL;
use crate::store::oauth::MAX_ACTIVE_OAUTH_STATES;
use crate::store::token::hash_token;

#[tokio::test]
async fn signing_out_clears_the_session_on_the_server() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/panel/auth/signout")
                .header(header::ORIGIN, harness.state.config.public_origin.as_str())
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

#[tokio::test]
async fn signing_out_without_a_session_sets_no_cookie() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
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

/// `SameSite=Lax` cookies are still sent between different origins on the same
/// site, so the sign-out endpoint must verify the browser-supplied origin.
#[tokio::test]
async fn signing_out_from_a_missing_or_different_origin_is_refused() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("ada").await;

    for origin in [
        None,
        Some("https://attacker.example.com"),
        Some("https://harness.example.com/"),
    ] {
        let mut request = Request::builder()
            .method("POST")
            .uri("/panel/auth/signout")
            .header(header::COOKIE, format!("{SESSION_COOKIE}={token}"));
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

#[tokio::test]
async fn a_full_oauth_state_budget_evicts_the_oldest_and_starts() {
    let harness = Harness::new("ada").await;
    for index in 0..MAX_ACTIVE_OAUTH_STATES {
        sqlx::query(
            "INSERT INTO oauth_states (state_hash, created_at, expires_at) VALUES (?1, ?2, ?3)",
        )
        .bind(format!("occupied-{index}"))
        .bind(index)
        .bind(i64::MAX)
        .execute(harness.state.store.pool())
        .await
        .expect("fill state budget");
    }

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
    let location = response
        .headers()
        .get(header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("github redirect");
    let state = url::Url::parse(location)
        .expect("authorize url")
        .query_pairs()
        .find(|(key, _)| key == "state")
        .map(|(_, value)| value.into_owned())
        .expect("new state");
    assert!(response.headers().get(header::SET_COOKIE).is_some());

    let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states")
        .fetch_one(harness.state.store.pool())
        .await
        .expect("count");
    let oldest: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states WHERE state_hash = 'occupied-0'")
            .fetch_one(harness.state.store.pool())
            .await
            .expect("oldest");
    let issued: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM oauth_states WHERE state_hash = ?1")
        .bind(hash_token(&state))
        .fetch_one(harness.state.store.pool())
        .await
        .expect("issued");

    assert_eq!(stored, MAX_ACTIVE_OAUTH_STATES);
    assert_eq!(oldest, 0);
    assert_eq!(issued, 1);
}

/// Two start requests can leave the same browser snapshot concurrently. Their
/// responses must commute when the browser applies both `Set-Cookie` headers;
/// neither may overwrite the other's state.
#[tokio::test]
async fn concurrent_tabs_can_both_finish_a_sign_in() {
    let harness = Harness::with_unreachable_github("ada").await;

    let (first, second) = tokio::join!(harness.start_sign_in(None), harness.start_sign_in(None));
    let first_name = first.cookie.split_once('=').expect("cookie pair").0;
    let second_name = second.cookie.split_once('=').expect("cookie pair").0;
    assert_ne!(first_name, second_name);
    let cookies = format!("{}; {}", first.cookie, second.cookie);

    for started in [first, second] {
        let response = router(harness.state.clone())
            .oneshot(
                Request::builder()
                    .uri(format!(
                        "/panel/auth/github/callback?code=abc&state={}",
                        started.state
                    ))
                    .header(header::COOKIE, &cookies)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");
        let expired = response
            .headers()
            .get_all(header::SET_COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .find(|value| value.starts_with(&sign_in_cookie_name(&started.state)))
            .expect("only this sign-in cookie is expired");
        assert!(expired.contains("Max-Age=0"), "{expired}");
        let body = String::from_utf8_lossy(
            &to_bytes(response.into_body(), BODY_LIMIT)
                .await
                .expect("body"),
        )
        .into_owned();
        assert!(
            !body.contains("did not start this sign-in"),
            "a concurrent start overwrote this tab: {body}"
        );
    }
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
    let cookie_name = sign_in_cookie_name("whatever");

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri("/panel/auth/github/callback?code=abc&state=whatever")
                .header(header::COOKIE, format!("{cookie_name}=whatever"))
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
        .find(|value| value.starts_with(&cookie_name))
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

#[tokio::test]
async fn a_callback_github_refused_consumes_its_valid_state() {
    let harness = Harness::new("ada").await;
    let started = harness.start_sign_in(None).await;

    let response = router(harness.state.clone())
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/panel/auth/github/callback?error=access_denied&\
                     error_description=The+user+said+no&state={}",
                    started.state
                ))
                .header(header::COOKIE, started.cookie)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    let status = response.status();
    let body = String::from_utf8_lossy(
        &to_bytes(response.into_body(), BODY_LIMIT)
            .await
            .expect("body"),
    )
    .into_owned();

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body.contains("The user said no"), "{body}");
    assert!(
        !harness
            .state
            .store
            .consume_oauth_state(&started.state, chrono::Utc::now())
            .await
            .expect("state lookup"),
        "the refused callback left its state reusable"
    );
}
