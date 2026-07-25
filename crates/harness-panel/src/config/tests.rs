use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;

use super::{
    DEFAULT_GITHUB_API_URL, DEFAULT_GITHUB_AUTHORIZE_URL, DEFAULT_GITHUB_TOKEN_URL, PanelArgs,
    normalize_base_path, normalize_public_origin,
};

fn secret_file(directory: &Path) -> PathBuf {
    let path = directory.join("secret");
    fs::write(&path, "s3cret\n").expect("writing the secret");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .expect("restricting the secret");
    }
    path
}

fn args(directory: &Path) -> PanelArgs {
    PanelArgs {
        listen: "127.0.0.1:0".parse().expect("listen address"),
        public_origin: "https://harness.example.com".to_owned(),
        base_path: "/panel".to_owned(),
        state_dir: directory.join("state"),
        github_client_id: "Iv1.abc".to_owned(),
        github_client_secret_file: secret_file(directory),
        owner_login: "Ada".to_owned(),
        github_authorize_url: DEFAULT_GITHUB_AUTHORIZE_URL.to_owned(),
        github_token_url: DEFAULT_GITHUB_TOKEN_URL.to_owned(),
        github_api_url: DEFAULT_GITHUB_API_URL.to_owned(),
        session_ttl_hours: 12,
    }
}

#[test]
fn resolves_a_complete_configuration() {
    let directory = tempfile::tempdir().expect("temp dir");

    let config = args(directory.path())
        .resolve()
        .expect("valid configuration");

    assert_eq!(config.public_origin, "https://harness.example.com");
    assert_eq!(config.base_path, "/panel");
    assert!(config.cookie_is_secure());
    assert_eq!(config.session_ttl.num_hours(), 12);
}

/// GitHub matches the `redirect_uri` against the OAuth app's registration
/// exactly, so this string has to be built the same way every time rather than
/// derived from whatever the request carried.
#[test]
fn every_url_is_built_from_the_origin_and_the_mount_point() {
    let directory = tempfile::tempdir().expect("temp dir");

    let config = args(directory.path())
        .resolve()
        .expect("valid configuration");

    assert_eq!(
        config.callback_url(),
        "https://harness.example.com/panel/auth/github/callback"
    );
    assert_eq!(config.landing_path(), "/panel/");
    assert_eq!(config.cookie_path(), "/panel");
}

/// GitHub treats a login case-insensitively, so an owner who typed their login
/// with different capitalisation than GitHub reports must still be the owner.
#[test]
fn owner_matching_ignores_case() {
    let directory = tempfile::tempdir().expect("temp dir");

    let config = args(directory.path())
        .resolve()
        .expect("valid configuration");

    assert!(config.is_owner("ada"));
    assert!(config.is_owner("ADA"));
    assert!(!config.is_owner("adam"));
}

#[test]
fn refuses_a_blank_owner_login() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args(directory.path());
    args.owner_login = "   ".to_owned();

    let error = args.resolve().expect_err("a blank owner must be refused");

    assert!(error.to_string().contains("--owner-login"), "{error}");
}

/// A zero-hour session expires before the browser can send the cookie back, so
/// sign-in would appear to succeed and then never take effect.
#[test]
fn refuses_a_session_that_expires_immediately() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args(directory.path());
    args.session_ttl_hours = 0;

    let error = args.resolve().expect_err("a zero TTL must be refused");

    assert!(error.to_string().contains("--session-ttl-hours"), "{error}");
}

/// The flag is a `u32`, so an operator can name a deadline that runs off the
/// end of the calendar `chrono` represents. Unbounded, that panics inside
/// `create_session` on the first sign-in instead of refusing to start.
#[test]
fn refuses_a_session_longer_than_the_calendar() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args(directory.path());
    args.session_ttl_hours = u32::MAX;

    let error = args.resolve().expect_err("an unbounded TTL must be refused");

    assert!(error.to_string().contains("--session-ttl-hours"), "{error}");

    args.session_ttl_hours = super::MAX_SESSION_TTL_HOURS;
    let config = args.resolve().expect("the bound itself is usable");
    assert!(
        Utc::now().checked_add_signed(config.session_ttl).is_some(),
        "a session issued at the bound has to have a representable expiry"
    );
}

#[test]
fn normalizes_the_mount_point() {
    for raw in ["/panel", "/panel/", " /panel// "] {
        assert_eq!(normalize_base_path(raw).expect("valid mount"), "/panel");
    }
    assert_eq!(
        normalize_base_path("/harness/panel").expect("valid nested mount"),
        "/harness/panel"
    );
}

/// Mounting at the origin root would scope the session cookie to the daemon's
/// own API, which is served from the same origin.
#[test]
fn refuses_the_origin_root_as_a_mount_point() {
    for raw in ["/", "//"] {
        let error = normalize_base_path(raw).expect_err("the root must be refused");
        assert!(error.to_string().contains("subtree"), "{error}");
    }
}

#[test]
fn refuses_a_mount_point_that_is_not_a_plain_path() {
    for raw in ["panel", "/panel?x=1", "/panel#top", "/pa nel", "/pa\nnel"] {
        assert!(
            normalize_base_path(raw).is_err(),
            "{raw:?} should be refused"
        );
    }
}

#[test]
fn refuses_an_empty_segment_inside_the_mount_point() {
    let error = normalize_base_path("/harness//panel").expect_err("an empty segment is refused");

    assert!(error.to_string().contains("empty segment"), "{error}");
}

#[test]
fn reduces_the_public_origin_to_scheme_host_and_port() {
    assert_eq!(
        normalize_public_origin("https://harness.example.com/").expect("valid origin"),
        "https://harness.example.com"
    );
    assert_eq!(
        normalize_public_origin("http://127.0.0.1:8787").expect("valid loopback origin"),
        "http://127.0.0.1:8787"
    );
}

/// The mount point is `--base-path`; accepting a path here would produce a
/// `redirect_uri` with the prefix twice over.
#[test]
fn refuses_a_public_origin_carrying_a_path() {
    for raw in [
        "https://harness.example.com/panel",
        "https://harness.example.com/?a=1",
        "https://harness.example.com/#top",
    ] {
        let error = normalize_public_origin(raw).expect_err("a non-origin must be refused");
        assert!(error.to_string().contains("--base-path"), "{error}");
    }
}

/// A `Secure` cookie is dropped over plain HTTP, so a public HTTP origin would
/// hand every session token to the network instead.
#[test]
fn refuses_plain_http_away_from_loopback() {
    let error =
        normalize_public_origin("http://harness.example.com").expect_err("http must be refused");

    assert!(error.to_string().contains("https"), "{error}");
    assert!(normalize_public_origin("http://localhost:8787").is_ok());
}

#[test]
fn refuses_a_public_origin_that_is_not_http() {
    for raw in ["ftp://harness.example.com", "harness.example.com", ""] {
        assert!(
            normalize_public_origin(raw).is_err(),
            "{raw:?} should be refused"
        );
    }
}

/// Serving over loopback HTTP is how the panel is developed, and a cookie the
/// browser refuses to store would make sign-in appear to fail.
#[test]
fn a_loopback_origin_drops_the_secure_attribute() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args(directory.path());
    args.public_origin = "http://127.0.0.1:8787".to_owned();

    let config = args.resolve().expect("valid loopback configuration");

    assert!(!config.cookie_is_secure());
}

#[test]
fn refuses_a_github_endpoint_that_is_not_http() {
    let directory = tempfile::tempdir().expect("temp dir");
    let mut args = args(directory.path());
    args.github_token_url = "file:///etc/passwd".to_owned();

    let error = args.resolve().expect_err("a file url must be refused");

    assert!(error.to_string().contains("--github-token-url"), "{error}");
}
