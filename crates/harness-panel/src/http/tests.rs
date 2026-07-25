//! Live-router tests for everything that does not need GitHub.
//!
//! The sign-in round trip needs a stub GitHub and lives in
//! `tests/sign_in.rs`; these cover what the panel decides on its own.

use std::fs;
use std::path::Path;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use chrono::{Duration, Utc};
use tower::ServiceExt;

use super::session::SESSION_COOKIE;
use super::{PanelState, router};
use crate::config::{
    DEFAULT_GITHUB_API_URL, DEFAULT_GITHUB_AUTHORIZE_URL, DEFAULT_GITHUB_TOKEN_URL, PanelArgs,
};
use crate::store::Store;
use crate::store::accounts::AccountIdentity;

const BODY_LIMIT: usize = 1024 * 1024;

fn args(directory: &Path, owner_login: &str) -> PanelArgs {
    let secret = directory.join("secret");
    fs::write(&secret, "s3cret").expect("writing the secret");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600))
            .expect("restricting the secret");
    }

    PanelArgs {
        listen: "127.0.0.1:0".parse().expect("listen address"),
        public_origin: "https://harness.example.com".to_owned(),
        base_path: "/panel".to_owned(),
        state_dir: directory.join("state"),
        github_client_id: "Iv1.abc".to_owned(),
        github_client_secret_file: secret,
        owner_login: owner_login.to_owned(),
        github_authorize_url: DEFAULT_GITHUB_AUTHORIZE_URL.to_owned(),
        github_token_url: DEFAULT_GITHUB_TOKEN_URL.to_owned(),
        github_api_url: DEFAULT_GITHUB_API_URL.to_owned(),
        session_ttl_hours: 12,
    }
}

struct Harness {
    state: PanelState,
    _directory: tempfile::TempDir,
}

impl Harness {
    async fn new(owner_login: &str) -> Self {
        let directory = tempfile::tempdir().expect("temp dir");
        let config = args(directory.path(), owner_login)
            .resolve()
            .expect("valid configuration");
        let store = Store::open_in_memory().await.expect("store");
        let state = PanelState::new(config, store).expect("panel state");
        Self {
            state,
            _directory: directory,
        }
    }

    async fn sign_in(&self, login: &str) -> String {
        let identity = AccountIdentity {
            provider: "github".to_owned(),
            subject_id: login.to_owned(),
            login: login.to_owned(),
            display_name: login.to_owned(),
            avatar_url: None,
        };
        let account = self
            .state
            .store
            .upsert_account(&identity, Utc::now())
            .await
            .expect("account");
        self.state
            .store
            .create_session(&account.id, Duration::hours(12), Utc::now())
            .await
            .expect("session")
            .expose()
            .to_owned()
    }

    async fn get(&self, path: &str, session: Option<&str>) -> (StatusCode, String) {
        let mut request = Request::builder().uri(path);
        if let Some(token) = session {
            request = request.header(header::COOKIE, format!("{SESSION_COOKIE}={token}"));
        }
        let response = router(self.state.clone())
            .oneshot(request.body(Body::empty()).expect("request"))
            .await
            .expect("response");
        let status = response.status();
        let bytes = to_bytes(response.into_body(), BODY_LIMIT)
            .await
            .expect("body");
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }
}

#[tokio::test]
async fn healthz_reports_the_embedded_bundle() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness.get("/panel/healthz", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"status\":\"ok\""), "{body}");
    assert!(body.contains("\"assets\":\"bundled\""), "{body}");
}

/// The single-page app treats 401 as "not signed in yet" rather than an error,
/// so the status matters as much as the body.
#[tokio::test]
async fn asking_who_is_signed_in_without_a_session_is_a_401() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness.get("/panel/api/me", None).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert!(body.contains("\"code\":\"unauthenticated\""), "{body}");
}

#[tokio::test]
async fn a_session_identifies_its_account() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("grace").await;

    let (status, body) = harness.get("/panel/api/me", Some(&token)).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"login\":\"grace\""), "{body}");
    assert!(body.contains("\"is_owner\":false"), "{body}");
}

/// GitHub logins are case-insensitive for one account, so an owner whose flag
/// was typed differently than GitHub reports must still be the owner.
#[tokio::test]
async fn the_owner_is_recognised_whatever_the_case() {
    let harness = Harness::new("Ada").await;
    let token = harness.sign_in("ada").await;

    let (status, body) = harness.get("/panel/api/me", Some(&token)).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"is_owner\":true"), "{body}");
}

/// Knowing who else has signed in is the owner's view of the panel; anyone
/// else learning it would be a roster of the owner's collaborators.
#[tokio::test]
async fn only_the_owner_can_list_accounts() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let other = harness.sign_in("grace").await;

    let (owner_status, owner_body) = harness.get("/panel/api/accounts", Some(&owner)).await;
    let (other_status, other_body) = harness.get("/panel/api/accounts", Some(&other)).await;
    let (anonymous_status, _) = harness.get("/panel/api/accounts", None).await;

    assert_eq!(owner_status, StatusCode::OK);
    assert!(owner_body.contains("\"login\":\"grace\""), "{owner_body}");
    assert_eq!(other_status, StatusCode::FORBIDDEN);
    assert!(
        other_body.contains("\"code\":\"forbidden\""),
        "{other_body}"
    );
    assert_eq!(anonymous_status, StatusCode::UNAUTHORIZED);
}

/// A token the panel never issued must not resolve to whoever happens to be
/// first in the table.
#[tokio::test]
async fn an_unknown_session_token_is_not_a_session() {
    let harness = Harness::new("ada").await;
    harness.sign_in("ada").await;

    let (status, _) = harness.get("/panel/api/me", Some("forged-token")).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

/// Both spellings of the mount point are what people type and what links
/// produce, and only one of them can come from a browser's address bar.
#[tokio::test]
async fn the_entry_page_is_served_at_the_mount_point_with_or_without_a_slash() {
    let harness = Harness::new("ada").await;

    for path in ["/panel", "/panel/"] {
        let (status, body) = harness.get(path, None).await;

        assert_eq!(status, StatusCode::OK, "{path}");
        assert!(body.contains("harness-panel-base"), "{path}: {body}");
        assert!(body.contains(r#"content="/panel""#), "{path}: {body}");
    }
}

/// A reload or a bookmark of an app route has to reach the app, which only the
/// entry page can dispatch.
#[tokio::test]
async fn an_unknown_path_under_the_mount_point_falls_back_to_the_app() {
    let harness = Harness::new("ada").await;

    let (status, body) = harness.get("/panel/accounts", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<div id=\"app\">"), "{body}");
}

/// The daemon forwards only its companion prefix, but the panel must not serve
/// anything outside it even when reached directly over loopback.
#[tokio::test]
async fn nothing_is_served_outside_the_mount_point() {
    let harness = Harness::new("ada").await;

    for path in ["/", "/healthz", "/api/me", "/panelx/healthz"] {
        let (status, _) = harness.get(path, None).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{path} should not be served");
    }
}

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
