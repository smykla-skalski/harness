use super::{
    CompanionAuthToken, CompanionConfigError, CompanionRouteConfig, DEFAULT_COMPANION_PATH_PREFIX,
};

fn config(upstream: &str, prefix: &str) -> Result<CompanionRouteConfig, CompanionConfigError> {
    let token =
        CompanionAuthToken::parse("daemon-panel-test-token-0123456789").expect("valid test token");
    CompanionRouteConfig::new(upstream, prefix, token)
}

#[test]
fn accepts_a_loopback_upstream_and_normalizes_nothing() {
    let route = config("http://127.0.0.1:8787", DEFAULT_COMPANION_PATH_PREFIX)
        .expect("loopback upstream is accepted");

    assert_eq!(route.upstream_origin(), "http://127.0.0.1:8787");
    assert_eq!(route.path_prefix(), "/panel");
}

#[test]
fn auth_token_debug_output_is_redacted() {
    let secret = "never-print-this-companion-token-123";
    let token = CompanionAuthToken::parse(secret).expect("valid token");
    let route = CompanionRouteConfig::new("http://127.0.0.1:8787", "/panel", token.clone())
        .expect("valid route");

    for debug in [format!("{token:?}"), format!("{route:?}")] {
        assert!(debug.contains("REDACTED"));
        assert!(!debug.contains(secret));
    }
}

#[test]
fn auth_token_requires_a_long_visible_ascii_value() {
    for invalid in [
        "",
        "short",
        "0123456789012345678901234567890",
        "0123456789012345 7890123456789012",
        "0123456789012345\t7890123456789012",
        "012345678901234567890123456789é",
        "012345678901234567890123456789\u{7f}",
    ] {
        assert!(
            CompanionAuthToken::parse(invalid).is_err(),
            "{invalid:?} must not become an HTTP credential"
        );
    }
}

#[cfg(unix)]
#[test]
fn auth_token_file_must_be_private_and_trims_outer_whitespace() {
    use std::os::unix::fs::PermissionsExt as _;

    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.path().join("companion-token");
    let secret = "private-daemon-panel-token-0123456789";
    std::fs::write(&path, format!("\n{secret}\n")).expect("write token");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640))
        .expect("make token group-readable");

    let error = CompanionAuthToken::read_private_file(&path)
        .expect_err("group-readable token file must be rejected");
    assert!(matches!(
        error,
        CompanionConfigError::AuthTokenPermissionsTooOpen(_)
    ));
    assert!(
        !error.to_string().contains(secret),
        "validation errors must not disclose the credential"
    );

    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .expect("make token private");
    let token = CompanionAuthToken::read_private_file(&path).expect("read private token");

    assert_eq!(token.authorization_header(), format!("Bearer {secret}"));
}

#[test]
fn accepts_an_ipv6_loopback_literal() {
    config("http://[::1]:8787", "/panel").expect("IPv6 loopback should be accepted");
}

#[test]
fn accepts_an_uppercase_scheme() {
    let route =
        config("HTTP://127.0.0.1:8787", "/panel").expect("scheme compares case-insensitively");

    assert_eq!(route.upstream_origin(), "http://127.0.0.1:8787");
}

#[test]
fn accepts_a_trailing_root_path_on_the_upstream() {
    let route = config("http://127.0.0.1:8787/", "/panel").expect("root path is accepted");

    assert_eq!(route.upstream_origin(), "http://127.0.0.1:8787");
}

#[test]
fn rejects_a_non_loopback_upstream() {
    let error = config("http://198.51.100.9:8787", "/panel")
        .expect_err("a routable upstream must be refused");

    assert!(matches!(
        error,
        CompanionConfigError::UpstreamNotLoopback(_)
    ));
}

#[test]
fn rejects_every_named_upstream() {
    for upstream in ["http://localhost:8787", "http://panel.internal:8787"] {
        let error = config(upstream, "/panel").expect_err("a named host must be refused");

        assert!(matches!(
            error,
            CompanionConfigError::UpstreamNotLoopback(_)
        ));
    }
}

#[test]
fn rejects_a_non_http_upstream() {
    let error =
        config("https://127.0.0.1:8787", "/panel").expect_err("https upstream must be refused");

    assert!(matches!(
        error,
        CompanionConfigError::UpstreamSchemeUnsupported(_)
    ));
}

#[test]
fn rejects_an_upstream_carrying_a_path_or_query() {
    for upstream in ["http://127.0.0.1:8787/panel", "http://127.0.0.1:8787?x=1"] {
        let Err(error) = config(upstream, "/panel") else {
            panic!("{upstream} must be refused as more than an origin");
        };

        assert!(
            matches!(error, CompanionConfigError::UpstreamHasPathOrQuery(_)),
            "{upstream} should report the path-or-query rejection, got {error}"
        );
        assert!(
            error.to_string().contains("no path or query"),
            "the message must name both, got {error}"
        );
        assert!(
            error.to_string().contains(upstream),
            "the message must echo what was configured, got {error}"
        );
    }
}

#[test]
fn rejects_an_upstream_carrying_userinfo() {
    for upstream in [
        "http://user:pass@127.0.0.1:8787",
        "http://user@localhost:8787",
    ] {
        let Err(error) = config(upstream, "/panel") else {
            panic!("{upstream} must be refused rather than carried into the origin");
        };

        assert!(
            matches!(error, CompanionConfigError::UpstreamHasUserinfo(_)),
            "{upstream} should report the userinfo rejection, got {error}"
        );
    }
}

#[test]
fn rejects_a_missing_upstream() {
    let error = config("   ", "/panel").expect_err("blank upstream must be refused");

    assert!(matches!(error, CompanionConfigError::UpstreamMissingHost));
}

#[test]
fn rejects_a_prefix_that_shadows_the_daemon_api() {
    for prefix in ["/v1", "/v1/remote", "/V1"] {
        let Err(error) = config("http://127.0.0.1:8787", prefix) else {
            panic!("{prefix} should be refused as shadowing the daemon API");
        };

        assert!(
            matches!(error, CompanionConfigError::PrefixShadowsDaemonApi(_)),
            "{prefix} should be refused as shadowing, got {error}"
        );
    }
}

#[test]
fn rejects_a_root_prefix() {
    let error = config("http://127.0.0.1:8787", "/").expect_err("root prefix must be refused");

    assert!(matches!(error, CompanionConfigError::PrefixIsRoot));
}

#[test]
fn rejects_a_relative_or_trailing_slash_prefix() {
    let relative =
        config("http://127.0.0.1:8787", "panel").expect_err("relative prefix must be refused");
    let trailing =
        config("http://127.0.0.1:8787", "/panel/").expect_err("trailing slash must be refused");

    assert!(matches!(
        relative,
        CompanionConfigError::PrefixNotAbsolute(_)
    ));
    assert!(matches!(
        trailing,
        CompanionConfigError::PrefixTrailingSlash(_)
    ));
}

#[test]
fn rejects_a_prefix_with_an_empty_segment() {
    let error =
        config("http://127.0.0.1:8787", "/panel//api").expect_err("empty segment must be refused");

    assert!(matches!(error, CompanionConfigError::PrefixEmptySegment(_)));
}

#[test]
fn rejects_url_dot_segments_that_browsers_normalize_before_routing() {
    for prefix in [
        "/panel/./api",
        "/panel/../api",
        "/panel/%2e/api",
        "/panel/.%2E/api",
        "/panel/%2e./api",
        "/panel/%2E%2e/api",
    ] {
        let error =
            config("http://127.0.0.1:8787", prefix).expect_err("URL dot segment must be refused");

        assert!(
            matches!(error, CompanionConfigError::PrefixDotSegment(_)),
            "{prefix} should report the dot-segment rejection, got {error}"
        );
    }
}

#[test]
fn rejects_prefix_characters_that_would_change_routing_or_parsing() {
    // Kept in step with the systemd installer's own list, so a prefix accepted
    // at install time cannot be one the daemon refuses at startup.
    for prefix in [
        "/pa nel",
        "/panel\tapi",
        "/panel\u{7f}",
        "/panel?x=1",
        "/panel#top",
        "/{panel}",
        "/panel/*",
        "/:panel",
        "/panel/:api",
        "/panel\\x",
    ] {
        let Err(error) = config("http://127.0.0.1:8787", prefix) else {
            panic!("{prefix} should be refused for its characters");
        };

        assert!(
            matches!(error, CompanionConfigError::PrefixInvalidCharacter(_)),
            "{prefix} should be refused for its characters, got {error}"
        );
    }
}

#[test]
fn route_patterns_cover_the_prefix_and_its_subtree() {
    let route = config("http://127.0.0.1:8787", "/panel").expect("valid companion config");

    assert_eq!(
        route.routes(),
        [
            "/panel".to_owned(),
            "/panel/".to_owned(),
            "/panel/{*companion_path}".to_owned(),
        ],
        "the bare trailing slash needs its own pattern; {{*rest}} never matches an empty remainder"
    );
    // owns_route answers without rebuilding routes(), so the two must agree on
    // every pattern and disagree on everything else.
    for owned in route.routes() {
        assert!(route.owns_route(&owned), "{owned} must be recognised");
    }
    for foreign in [
        "/v1/ready",
        "/panelling",
        "/pane",
        "/panel/{*other}",
        "/panel/api",
        "",
    ] {
        assert!(
            !route.owns_route(foreign),
            "{foreign} must not be claimed by the companion"
        );
    }
}
