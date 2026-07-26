//! The sign-in round trip, over real HTTP, against a stub GitHub.
//!
//! The unit tests cover each decision on its own. This one exists because the
//! parts that can only be wrong together — the redirect, the cookie, the state
//! the callback echoes, and the session it produces — are exactly the parts a
//! browser exercises.

mod support;

use reqwest::StatusCode;
use reqwest::header::SET_COOKIE;
use support::{GitHubStub, PanelUnderTest, state_from_authorize_url};

#[tokio::test]
async fn the_panel_serves_http2() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    let response = panel.get_over_http2("/panel/healthz").await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.version(), reqwest::Version::HTTP_2);
}

#[tokio::test]
async fn a_person_signs_in_and_the_panel_records_the_account() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "someone-else").await;

    let start = panel.get("/panel/auth/github/start", None).await;
    assert_eq!(start.status(), StatusCode::SEE_OTHER);
    let authorize = support::location(&start);
    let sign_in_cookie = support::sign_in_cookie(&start);
    let state = state_from_authorize_url(&authorize);

    let callback = panel
        .get(
            &format!("/panel/auth/github/callback?code=valid-code&state={state}"),
            Some(&sign_in_cookie),
        )
        .await;

    assert_eq!(callback.status(), StatusCode::SEE_OTHER);
    assert_eq!(support::location(&callback), "/panel/");

    let session = support::session_cookie(&callback);
    let me = panel.get("/panel/api/me", Some(&session)).await;
    assert_eq!(me.status(), StatusCode::OK);
    let body = me.text().await.expect("body");
    assert!(body.contains("\"login\":\"ada\""), "{body}");
    assert!(body.contains("\"subject_id\":\"4242\""), "{body}");
    assert!(body.contains("\"is_owner\":false"), "{body}");

    // The token is spent reading the profile and never stored, so exactly one
    // exchange and one profile read should have happened.
    assert_eq!(github.token_exchanges(), 1);
    assert_eq!(github.profile_reads(), 1);
}

/// Replaying a callback URL is what an attacker does with one seen in a
/// referrer header, a proxy log, or browser history.
#[tokio::test]
async fn a_callback_cannot_be_replayed() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    let start = panel.get("/panel/auth/github/start", None).await;
    let sign_in_cookie = support::sign_in_cookie(&start);
    let state = state_from_authorize_url(&support::location(&start));
    let path = format!("/panel/auth/github/callback?code=valid-code&state={state}");

    let first = panel.get(&path, Some(&sign_in_cookie)).await;
    assert_eq!(first.status(), StatusCode::SEE_OTHER);

    let replayed = panel.get(&path, Some(&sign_in_cookie)).await;

    assert_eq!(replayed.status(), StatusCode::BAD_REQUEST);
    let body = replayed.text().await.expect("body");
    assert!(body.contains("expired or already finished"), "{body}");
}

/// Without the cookie check, anyone can fetch a valid state from the panel and
/// hand a victim a finished callback URL, signing them into the attacker's
/// account.
#[tokio::test]
async fn a_state_from_another_browser_is_refused() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    let attacker = panel.get("/panel/auth/github/start", None).await;
    let attacker_state = state_from_authorize_url(&support::location(&attacker));
    let victim = panel.get("/panel/auth/github/start", None).await;
    let victim_cookie = support::sign_in_cookie(&victim);

    let forged = panel
        .get(
            &format!("/panel/auth/github/callback?code=valid-code&state={attacker_state}"),
            Some(&victim_cookie),
        )
        .await;

    assert_eq!(forged.status(), StatusCode::BAD_REQUEST);
    let body = forged.text().await.expect("body");
    assert!(body.contains("did not start this sign-in"), "{body}");
    assert_eq!(github.token_exchanges(), 0, "no code should be exchanged");
}

/// GitHub answers a refused code with HTTP 200 and an `error` field, so this
/// only fails safely if the panel reads the body rather than the status.
#[tokio::test]
async fn a_code_github_refuses_never_becomes_a_session() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    let start = panel.get("/panel/auth/github/start", None).await;
    let sign_in_cookie = support::sign_in_cookie(&start);
    let state = state_from_authorize_url(&support::location(&start));

    let callback = panel
        .get(
            &format!("/panel/auth/github/callback?code=stale-code&state={state}"),
            Some(&sign_in_cookie),
        )
        .await;

    assert_eq!(callback.status(), StatusCode::BAD_REQUEST);
    assert!(
        callback
            .headers()
            .get_all(SET_COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .all(|value| !value.starts_with("harness_panel_session_")),
        "a refused sign-in must not set a session"
    );
    assert_eq!(github.profile_reads(), 0);
}

#[tokio::test]
async fn the_owner_sees_everyone_who_has_signed_in() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;
    let owner_session = panel.sign_in().await;

    github.become_user("grace", 99);
    let other_session = panel.sign_in().await;

    let owner_view = panel.get("/panel/api/accounts", Some(&owner_session)).await;
    assert_eq!(owner_view.status(), StatusCode::OK);
    let body = owner_view.text().await.expect("body");
    assert!(body.contains("\"login\":\"ada\""), "{body}");
    assert!(body.contains("\"login\":\"grace\""), "{body}");

    let other_view = panel.get("/panel/api/accounts", Some(&other_session)).await;
    assert_eq!(other_view.status(), StatusCode::FORBIDDEN);
}

/// Signing in twice is one account, because the panel keys on the immutable
/// numeric id rather than the login.
#[tokio::test]
async fn signing_in_again_after_a_rename_is_the_same_account() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;
    let first = panel.sign_in().await;

    github.become_user("ada-lovelace", 4242);
    let second = panel.sign_in().await;

    let me = panel.get("/panel/api/me", Some(&second)).await;
    let body = me.text().await.expect("body");
    assert!(body.contains("\"login\":\"ada-lovelace\""), "{body}");

    // The callback claimed the panel before the browser loaded `/api/me`, so a
    // later rename cannot make ownership depend on the configured login.
    assert!(body.contains("\"is_owner\":true"), "{body}");
    // The first session belongs to the same account and stays usable.
    assert_eq!(
        panel.get("/panel/api/me", Some(&first)).await.status(),
        StatusCode::OK
    );
}

/// Ownership is fixed by the successful callback, not by the redirected page
/// eventually loading `/api/me`. Closing that page must not leave the
/// configured login available for a later holder to claim.
#[tokio::test]
async fn closing_after_the_owner_callback_cannot_leave_a_takeover_window() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    panel.sign_in().await;
    github.become_user("ada", 7777);
    let stranger = panel.sign_in().await;

    let stranger_view = panel.get("/panel/api/me", Some(&stranger)).await;
    let stranger_body = stranger_view.text().await.expect("body");
    assert!(
        stranger_body.contains("\"is_owner\":false"),
        "{stranger_body}"
    );

    github.become_user("ada-lovelace", 4242);
    let renamed_owner = panel.sign_in().await;
    let owner_view = panel.get("/panel/api/me", Some(&renamed_owner)).await;
    let owner_body = owner_view.text().await.expect("body");
    assert!(owner_body.contains("\"is_owner\":true"), "{owner_body}");
}

#[tokio::test]
async fn signing_out_ends_the_session_for_good() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;
    let session = panel.sign_in().await;

    let signout = panel.post("/panel/auth/signout", Some(&session)).await;
    assert_eq!(signout.status(), StatusCode::NO_CONTENT);

    assert_eq!(
        panel.get("/panel/api/me", Some(&session)).await.status(),
        StatusCode::UNAUTHORIZED
    );
}

/// The whole point of the companion mount is that the daemon forwards one
/// subtree; anything the panel answered outside it would be unreachable in
/// production and misleading in development.
#[tokio::test]
async fn the_panel_answers_only_under_its_mount_point() {
    let github = GitHubStub::start("ada", 4242).await;
    let panel = PanelUnderTest::start(&github, "ada").await;

    for path in ["/", "/api/me", "/healthz", "/auth/github/start"] {
        assert_eq!(
            panel.get(path, None).await.status(),
            StatusCode::NOT_FOUND,
            "{path} should not be served"
        );
    }
    assert_eq!(
        panel.get("/panel/healthz", None).await.status(),
        StatusCode::OK
    );
}
