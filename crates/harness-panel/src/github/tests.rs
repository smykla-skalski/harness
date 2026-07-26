use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Router;
use axum::http::{StatusCode, header};
use axum::routing::post;
use tokio::net::TcpListener;
use url::Url;

use super::{
    GitHubClient, GitHubSignInError, GitHubUser, MAX_FIELD_CHARS, identity_from_user,
    installation_provider, join_api_path, parse_token_response,
};
use crate::config::{ClientSecret, GitHubConfig};
use crate::error::PanelError;
use crate::store::accounts::AccountIdentity;

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

fn identity(user: GitHubUser) -> Result<AccountIdentity, PanelError> {
    identity_from_user(user, "github:https://api.github.com")
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

    assert!(matches!(error, GitHubSignInError::Refused(_)));
    assert!(
        error.to_string().contains("The code is incorrect."),
        "{error}"
    );
}

#[test]
fn a_token_response_without_a_token_is_a_failure() {
    for body in [r"{}", r#"{"access_token":""}"#, r#"{"access_token":"  "}"#] {
        assert!(matches!(
            parse_token_response(body),
            Err(GitHubSignInError::Internal(_))
        ));
    }
    assert!(matches!(
        parse_token_response("not json"),
        Err(GitHubSignInError::Internal(_))
    ));
}

#[test]
fn a_profile_becomes_an_account_identity() {
    let identity = identity(user()).expect("identity");

    assert_eq!(identity.provider, "github:https://api.github.com");
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
    let identity = identity(GitHubUser {
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
        let identity = identity(GitHubUser { name, ..user() }).expect("identity");
        assert_eq!(identity.display_name, "ada");
    }
}

/// These fields are rendered into the panel's pages and, in the next slice,
/// into the pairing subject the daemon records in its audit trail.
#[test]
fn a_profile_field_with_a_control_character_is_refused() {
    let error = identity(GitHubUser {
        name: Some("Ada\nminted for github:9".to_owned()),
        ..user()
    })
    .expect_err("a newline must be refused");

    assert!(error.to_string().contains("control characters"), "{error}");
}

#[test]
fn a_blank_login_is_refused() {
    let error = identity(GitHubUser {
        login: "  ".to_owned(),
        ..user()
    })
    .expect_err("a blank login must be refused");

    assert!(error.to_string().contains("login"), "{error}");
}

#[test]
fn an_oversized_profile_field_is_refused() {
    let error = identity(GitHubUser {
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
        let error = identity(GitHubUser {
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
        let identity = identity(GitHubUser {
            avatar_url: avatar,
            ..user()
        })
        .expect("identity");
        assert!(identity.avatar_url.is_none());
    }
}

#[test]
fn equal_subjects_from_different_installations_have_different_keys() {
    let github = installation_provider(&Url::parse("https://api.github.com").expect("url"));
    let enterprise =
        installation_provider(&Url::parse("https://ghe.example.com/api/v3").expect("url"));

    assert_ne!(github, enterprise);
    assert_eq!(github, "github:https://api.github.com");
    assert_eq!(enterprise, "github:https://ghe.example.com/api/v3");
}

#[test]
fn equivalent_enterprise_api_paths_have_one_installation_key() {
    for api_url in [
        "https://ghe.example.com/api/v3",
        "https://ghe.example.com/api/v3/",
    ] {
        assert_eq!(
            installation_provider(&Url::parse(api_url).expect("url")),
            "github:https://ghe.example.com/api/v3"
        );
    }
}

#[test]
fn installations_beneath_one_gateway_have_distinct_keys() {
    let first =
        installation_provider(&Url::parse("https://gateway.example/first/api/v3").expect("url"));
    let second =
        installation_provider(&Url::parse("https://gateway.example/second/api/v3").expect("url"));

    assert_ne!(first, second);
}

#[test]
fn installation_keys_never_expose_url_credentials_or_queries() {
    let unsafe_url =
        Url::parse("https://user:password@gateway.example/api/v3?token=secret#fragment")
            .expect("url");

    assert_eq!(
        installation_provider(&unsafe_url),
        "github:https://gateway.example/api/v3"
    );
}

/// Reqwest follows redirects by default, including 307 responses that retain
/// the POST body. The OAuth client secret must never be replayed to a location
/// that did not pass configuration validation.
#[tokio::test]
async fn token_exchange_refuses_redirects_before_replaying_credentials() {
    let target_hits = Arc::new(AtomicUsize::new(0));
    let hits = Arc::clone(&target_hits);
    let target = spawn(Router::new().route(
        "/stolen",
        post(move || {
            let hits = Arc::clone(&hits);
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                StatusCode::NO_CONTENT
            }
        }),
    ))
    .await;
    let target_url = target.join("stolen").expect("target url").to_string();
    let redirector = spawn(Router::new().route(
        "/token",
        post(move || {
            let target_url = target_url.clone();
            async move {
                (
                    StatusCode::TEMPORARY_REDIRECT,
                    [(header::LOCATION, target_url)],
                )
            }
        }),
    ))
    .await;
    let mut config = config();
    config.token_url = redirector.join("token").expect("token url");
    let client =
        GitHubClient::new(config, "https://panel.example/callback".to_owned()).expect("client");

    let error = client
        .exchange_code("authorization-code")
        .await
        .expect_err("a redirect must not be followed");

    assert!(error.to_string().contains("307"), "{error}");
    assert_eq!(target_hits.load(Ordering::SeqCst), 0);
}

async fn spawn(app: Router) -> Url {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let address = listener.local_addr().expect("address");
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    Url::parse(&format!("http://{address}/")).expect("base url")
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
