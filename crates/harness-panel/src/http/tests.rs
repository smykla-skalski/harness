//! Live-router tests for everything that does not need GitHub.
//!
//! The sign-in round trip needs a stub GitHub and lives in
//! `tests/sign_in.rs`; these cover what the panel decides on its own.
//!
//! Starting, finishing, and ending a sign-in live in [`auth`]; this file
//! keeps the shared harness and the reading routes.

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

mod auth;

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

/// What a browser holds after one tab has started a sign-in.
struct StartedSignIn {
    state: String,
    /// The whole `name=value` pair, as the browser would send it back.
    cookie: String,
}

impl Harness {
    async fn new(owner_login: &str) -> Self {
        Self::build(owner_login, None).await
    }

    /// A panel whose token endpoint refuses connections at once.
    ///
    /// Lets a test drive a callback past state validation without reaching
    /// github.com: the sign-in then fails at the code exchange, which is a
    /// different failure from the one under test and arrives immediately.
    async fn with_unreachable_github(owner_login: &str) -> Self {
        Self::build(owner_login, Some("http://127.0.0.1:1/token")).await
    }

    async fn build(owner_login: &str, token_url: Option<&str>) -> Self {
        let directory = tempfile::tempdir().expect("temp dir");
        let mut raw = args(directory.path(), owner_login);
        if let Some(url) = token_url {
            raw.github_token_url = url.to_owned();
        }
        let config = raw.resolve().expect("valid configuration");
        let store = Store::open_in_memory().await.expect("store");
        let state = PanelState::new(config, store).expect("panel state");
        Self {
            state,
            _directory: directory,
        }
    }

    async fn sign_in(&self, login: &str) -> String {
        self.sign_in_as(login, login).await
    }

    /// Sign in a login and a subject id independently, so a test can replay the
    /// case GitHub allows: a login freed by a rename and taken by someone else.
    async fn sign_in_as(&self, login: &str, subject_id: &str) -> String {
        let identity = AccountIdentity {
            provider: "github".to_owned(),
            subject_id: subject_id.to_owned(),
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

    /// Open the start route as a browser would, optionally already holding the
    /// sign-in cookie an earlier tab was issued.
    async fn start_sign_in(&self, cookie: Option<&str>) -> StartedSignIn {
        let mut request = Request::builder().uri("/panel/auth/github/start");
        if let Some(cookie) = cookie {
            request = request.header(header::COOKIE, cookie);
        }
        let response = router(self.state.clone())
            .oneshot(request.body(Body::empty()).expect("request"))
            .await
            .expect("response");

        let location = response
            .headers()
            .get(header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .expect("a redirect to github")
            .to_owned();
        let state = url::Url::parse(&location)
            .expect("an authorize url")
            .query_pairs()
            .find(|(key, _)| key == "state")
            .map(|(_, value)| value.into_owned())
            .expect("the authorize url carries a state");
        let cookie = response
            .headers()
            .get_all(header::SET_COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .find(|value| value.starts_with("harness_panel_signin="))
            .and_then(|value| value.split(';').next())
            .expect("a sign-in cookie")
            .to_owned();

        StartedSignIn { state, cookie }
    }
}

/// The pending sign-ins a `name=value` cookie pair carries.
fn pending_states(cookie: &str) -> Vec<String> {
    cookie
        .split_once('=')
        .map(|(_, value)| value)
        .unwrap_or_default()
        .split('.')
        .filter(|candidate| !candidate.is_empty())
        .map(str::to_owned)
        .collect()
}

/// The point of the field is that a deploy which skipped the frontend build is
/// visible without loading a page, so the assertion is that `healthz` reports
/// the bundle this binary actually carries — not that it is always the real one.
#[tokio::test]
async fn healthz_reports_the_embedded_bundle() {
    let harness = Harness::new("ada").await;
    let expected = if harness.state.assets.is_placeholder() {
        "placeholder"
    } else {
        "bundled"
    };

    let (status, body) = harness.get("/panel/healthz", None).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"status\":\"ok\""), "{body}");
    assert!(
        body.contains(&format!("\"assets\":\"{expected}\"")),
        "{body}"
    );
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

/// GitHub frees a login when its owner renames, and anyone may then register
/// it. Ownership is pinned to the immutable subject id on first sign-in
/// precisely so that picking up the old name does not pick up the panel with
/// it, along with the roster of everyone who has ever signed in.
#[tokio::test]
async fn a_stranger_who_takes_the_freed_owner_login_is_not_the_owner() {
    let harness = Harness::new("ada").await;

    // The real owner signs in, which claims the panel for subject 4242.
    let owner = harness.sign_in_as("ada", "4242").await;
    assert!(
        harness
            .get("/panel/api/me", Some(&owner))
            .await
            .1
            .contains("\"is_owner\":true")
    );

    // They rename, freeing "ada", and a stranger registers it.
    harness.sign_in_as("ada-lovelace", "4242").await;
    let stranger = harness.sign_in_as("ada", "7777").await;

    let (status, body) = harness.get("/panel/api/me", Some(&stranger)).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"is_owner\":false"), "{body}");
    assert_eq!(
        harness.get("/panel/api/accounts", Some(&stranger)).await.0,
        StatusCode::FORBIDDEN
    );

    // The rename does not cost the real owner the panel either.
    let renamed = harness.sign_in_as("ada-lovelace", "4242").await;
    assert!(
        harness
            .get("/panel/api/me", Some(&renamed))
            .await
            .1
            .contains("\"is_owner\":true")
    );
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

/// These bodies belong to one session, and a 200 is heuristically cacheable, so
/// a proxy between the daemon and the browser would otherwise be free to hand
/// one person's answer to the next request.
#[tokio::test]
async fn session_derived_responses_are_never_cached() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;

    for path in ["/panel/api/me", "/panel/api/accounts"] {
        let response = router(harness.state.clone())
            .oneshot(
                Request::builder()
                    .uri(path)
                    .header(header::COOKIE, format!("{SESSION_COOKIE}={owner}"))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::OK, "{path}");
        assert_eq!(
            response
                .headers()
                .get(header::CACHE_CONTROL)
                .and_then(|value| value.to_str().ok()),
            Some("no-store"),
            "{path} must not be cacheable"
        );
    }
}
