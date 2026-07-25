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

/// GitHub treats a login case-insensitively, so the flag must match however it
/// was typed. This only decides who the panel is claimed for the first time;
/// ownership itself is pinned to the subject id in the owner binding.
#[test]
fn the_owner_login_flag_matches_without_regard_to_case() {
    let directory = tempfile::tempdir().expect("temp dir");

    let config = args(directory.path())
        .resolve()
        .expect("valid configuration");

    assert!(config.matches_owner_login("ada"));
    assert!(config.matches_owner_login("ADA"));
    assert!(!config.matches_owner_login("adam"));
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

    let error = args
        .resolve()
        .expect_err("an unbounded TTL must be refused");

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

/// A browser resolves `.` and `..` before it sends the request and before it
/// matches a cookie `Path`, so such a mount point would name one subtree in the
/// router and another in every request, and the session cookie would never come
/// back.
#[test]
fn refuses_a_dot_segment_inside_the_mount_point() {
    for raw in [
        "/panel/../api",
        "/panel/./api",
        "/./panel",
        "/panel/..",
        "/..",
    ] {
        let error = normalize_base_path(raw).expect_err(&format!("{raw} should be refused"));
        assert!(
            error.to_string().contains("'.'") || error.to_string().contains("subtree"),
            "{raw}: {error}"
        );
    }
}

/// A dot inside a segment is an ordinary character; only a whole segment of
/// dots redirects the path.
#[test]
fn accepts_a_dot_inside_a_segment() {
    assert_eq!(
        normalize_base_path("/panel.v2").expect("valid mount"),
        "/panel.v2"
    );
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

/// `host_str` returns a v6 address without its brackets, so rebuilding the
/// origin from it yields `http://::1:8787`, which is not a URL. Every absolute
/// URL the panel builds starts from this value, the OAuth `redirect_uri`
/// included.
#[test]
fn an_ipv6_origin_keeps_its_brackets() {
    assert_eq!(
        normalize_public_origin("http://[::1]:8787").expect("valid v6 loopback origin"),
        "http://[::1]:8787"
    );
    assert_eq!(
        normalize_public_origin("https://[2606:4700::1111]").expect("valid v6 origin"),
        "https://[2606:4700::1111]"
    );
}

/// Loopback is decided from the parsed address, so the forms nobody thinks to
/// spell out are covered too.
#[test]
fn loopback_is_recognised_in_every_form_it_is_written() {
    for raw in [
        "http://127.0.0.1",
        "http://127.0.0.2:9000",
        "http://localhost:8787",
        "http://LOCALHOST",
        "http://[::1]",
        "http://[0:0:0:0:0:0:0:1]:8787",
    ] {
        assert!(
            normalize_public_origin(raw).is_ok(),
            "{raw} should be accepted over plain http"
        );
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
