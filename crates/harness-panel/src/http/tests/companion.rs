//! The credential the daemon presents on every forwarded request.
//!
//! The panel is reachable over loopback by anything on the host, so this is the
//! only thing separating a forwarded request from a local process pretending to
//! be one. It is checked before routing, ahead of any session.

use axum::body::Body;
use axum::http::{HeaderValue, Method, Request, StatusCode, header};
use tower::ServiceExt;

use super::{Harness, router};

#[tokio::test]
async fn every_panel_route_requires_the_daemon_credential() {
    let harness = Harness::new("ada").await;

    for (method, path) in [
        (Method::GET, "/panel/healthz"),
        (Method::GET, "/panel/"),
        (Method::GET, "/panel/app.js"),
        (
            Method::GET,
            "/panel/auth/github/callback?code=abc&state=state",
        ),
        (Method::POST, "/panel/auth/signout"),
    ] {
        let response = router(harness.state.clone())
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
        assert_eq!(
            response.headers().get(header::WWW_AUTHENTICATE),
            Some(&HeaderValue::from_static("Bearer")),
            "{path}"
        );
    }
}

#[tokio::test]
async fn malformed_wrong_or_duplicate_daemon_credentials_are_refused() {
    let harness = Harness::new("ada").await;

    for authorization in [
        "Basic 0123456789abcdef0123456789abcdef",
        "bearer 0123456789abcdef0123456789abcdef",
        "Bearer 0123456789abcdef0123456789abcdee",
        "Bearer ",
    ] {
        let response = router(harness.state.clone())
            .oneshot(
                Request::builder()
                    .uri("/panel/healthz")
                    .header(header::AUTHORIZATION, authorization)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "{authorization}"
        );
    }

    let mut duplicate = Harness::request()
        .uri("/panel/healthz")
        .body(Body::empty())
        .expect("request");
    duplicate.headers_mut().append(
        header::AUTHORIZATION,
        HeaderValue::from_static("Bearer 0123456789abcdef0123456789abcdef"),
    );
    let response = router(harness.state.clone())
        .oneshot(duplicate)
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
