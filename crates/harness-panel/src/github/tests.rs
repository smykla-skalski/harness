use url::Url;

use super::{
    GitHubClient, GitHubUser, MAX_FIELD_CHARS, identity_from_user, join_api_path,
    parse_token_response,
};
use crate::config::{ClientSecret, GitHubConfig};

fn config() -> GitHubConfig {
    GitHubConfig {
        client_id: "Iv1.abc".to_owned(),
        client_secret: ClientSecret::from_value_for_tests("s3cret"),
        authorize_url: Url::parse("https://github.com/login/oauth/authorize").expect("url"),
        token_url: Url::parse("https://github.com/login/oauth/access_token").expect("url"),
        api_url: Url::parse("https://api.github.com").expect("url"),
    }
}

fn client() -> GitHubClient {
    GitHubClient::new(
        config(),
        "https://harness.example.com/panel/auth/github/callback".to_owned(),
    )
    .expect("client")
}

fn user() -> GitHubUser {
    GitHubUser {
        id: 4242,
        login: "ada".to_owned(),
        name: Some("Ada Lovelace".to_owned()),
        avatar_url: Some("https://avatars.example.com/ada.png".to_owned()),
    }
}

#[test]
fn the_authorize_url_carries_the_state_and_the_configured_callback() {
    let url = Url::parse(&client().authorize_url("state-value")).expect("authorize url");
    let pairs: Vec<(String, String)> = url
        .query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect();

    assert!(pairs.contains(&("state".to_owned(), "state-value".to_owned())));
    assert!(pairs.contains(&("client_id".to_owned(), "Iv1.abc".to_owned())));
    assert!(pairs.contains(&(
        "redirect_uri".to_owned(),
        "https://harness.example.com/panel/auth/github/callback".to_owned()
    )));
    assert!(pairs.contains(&("scope".to_owned(), "read:user".to_owned())));
}

/// The panel only needs to know who is signing in. A wider scope would make the
/// consent screen ask for access the panel has no use for.
#[test]
fn the_authorize_url_asks_only_to_read_the_profile() {
    let url = Url::parse(&client().authorize_url("state")).expect("authorize url");

    let scope = url
        .query_pairs()
        .find(|(key, _)| key == "scope")
        .map(|(_, value)| value.into_owned());

    assert_eq!(scope.as_deref(), Some("read:user"));
}

/// The client secret is a form field on the token request and must never end up
/// in a URL the browser is sent to.
#[test]
fn the_authorize_url_never_carries_the_client_secret() {
    assert!(!client().authorize_url("state").contains("s3cret"));
}

#[test]
fn a_token_response_yields_the_access_token() {
    let token = parse_token_response(r#"{"access_token":"gho_abc","token_type":"bearer"}"#)
        .expect("a token");

    assert_eq!(token, "gho_abc");
}

/// GitHub answers a refused code with HTTP 200 and an `error` field, so a
/// caller that only checked the status would call the API with no token.
#[test]
fn a_refused_code_is_a_failure_even_though_the_status_was_success() {
    let error = parse_token_response(
        r#"{"error":"bad_verification_code","error_description":"The code is incorrect."}"#,
    )
    .expect_err("a refused code must fail");

    assert!(
        error.to_string().contains("The code is incorrect."),
        "{error}"
    );
}

#[test]
fn a_token_response_without_a_token_is_a_failure() {
    for body in [r"{}", r#"{"access_token":""}"#, r#"{"access_token":"  "}"#] {
        assert!(
            parse_token_response(body).is_err(),
            "{body} should be refused"
        );
    }
    assert!(parse_token_response("not json").is_err());
}

#[test]
fn a_profile_becomes_an_account_identity() {
    let identity = identity_from_user(user()).expect("identity");

    assert_eq!(identity.provider, "github");
    assert_eq!(identity.subject_id, "4242");
    assert_eq!(identity.login, "ada");
    assert_eq!(identity.display_name, "Ada Lovelace");
    assert_eq!(
        identity.avatar_url.as_deref(),
        Some("https://avatars.example.com/ada.png")
    );
}

/// The account is keyed on the numeric id, not the login, because a login can
/// be renamed and then claimed by someone else.
#[test]
fn the_identity_is_keyed_on_the_immutable_numeric_id() {
    let identity = identity_from_user(GitHubUser {
        login: "ada-renamed".to_owned(),
        ..user()
    })
    .expect("identity");

    assert_eq!(identity.subject_id, "4242");
}

/// A profile with no display name is ordinary, and the login is the label the
/// person already recognises.
#[test]
fn a_missing_display_name_falls_back_to_the_login() {
    for name in [None, Some(String::new()), Some("   ".to_owned())] {
        let identity = identity_from_user(GitHubUser { name, ..user() }).expect("identity");
        assert_eq!(identity.display_name, "ada");
    }
}

/// These fields are rendered into the panel's pages and, in the next slice,
/// into the pairing subject the daemon records in its audit trail.
#[test]
fn a_profile_field_with_a_control_character_is_refused() {
    let error = identity_from_user(GitHubUser {
        name: Some("Ada\nminted for github:9".to_owned()),
        ..user()
    })
    .expect_err("a newline must be refused");

    assert!(error.to_string().contains("control characters"), "{error}");
}

#[test]
fn a_blank_login_is_refused() {
    let error = identity_from_user(GitHubUser {
        login: "  ".to_owned(),
        ..user()
    })
    .expect_err("a blank login must be refused");

    assert!(error.to_string().contains("login"), "{error}");
}

#[test]
fn an_oversized_profile_field_is_refused() {
    let error = identity_from_user(GitHubUser {
        name: Some("a".repeat(MAX_FIELD_CHARS + 1)),
        ..user()
    })
    .expect_err("an oversized name must be refused");

    assert!(error.to_string().contains("longer than"), "{error}");
}

/// The avatar becomes an `img` source on a page the owner opens, so a
/// `javascript:` URL would run in the panel's own origin.
#[test]
fn an_avatar_url_that_is_not_http_is_refused() {
    for avatar in [
        "javascript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "file:///etc/passwd",
    ] {
        let error = identity_from_user(GitHubUser {
            avatar_url: Some(avatar.to_owned()),
            ..user()
        })
        .expect_err("a non-http avatar must be refused");
        assert!(error.to_string().contains("http"), "{avatar}: {error}");
    }
}

#[test]
fn a_missing_avatar_is_not_a_failure() {
    for avatar in [None, Some(String::new())] {
        let identity = identity_from_user(GitHubUser {
            avatar_url: avatar,
            ..user()
        })
        .expect("identity");
        assert!(identity.avatar_url.is_none());
    }
}

/// A GitHub Enterprise API base carries a path, and joining onto it must extend
/// it rather than replace its last segment.
#[test]
fn the_api_path_extends_an_enterprise_base() {
    for (base, expected) in [
        ("https://api.github.com", "https://api.github.com/user"),
        (
            "https://ghe.example.com/api/v3",
            "https://ghe.example.com/api/v3/user",
        ),
        (
            "https://ghe.example.com/api/v3/",
            "https://ghe.example.com/api/v3/user",
        ),
    ] {
        let joined = join_api_path(&Url::parse(base).expect("base"), "user");
        assert_eq!(joined.as_str(), expected);
    }
}
