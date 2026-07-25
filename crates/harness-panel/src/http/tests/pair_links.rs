//! Who may ask for a pairing link, and what a refusal looks like.
//!
//! The daemon these tests point at does not exist, so a request that gets past
//! the panel's own checks fails at the connection. That is the point: it tells
//! the two apart. A 403 means the panel refused; anything else means it was
//! willing and the daemon was the problem.

use axum::http::StatusCode;

use super::Harness;

#[tokio::test]
async fn an_unapproved_account_is_refused() {
    let harness = Harness::new("ada").await;
    let grace = harness.sign_in("grace").await;

    let (status, body) = harness.post("/panel/api/pair-links", Some(&grace)).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(body.contains("\"code\":\"forbidden\""), "{body}");
    assert!(body.contains("has not allowed"), "{body}");
}

#[tokio::test]
async fn signing_out_is_not_a_way_to_generate_a_link() {
    let harness = Harness::new("ada").await;

    let (status, _) = harness.post("/panel/api/pair-links", None).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

/// Generating a link is a state change on the daemon, so a plain link or an
/// image tag must not carry it out.
#[tokio::test]
async fn generating_a_link_is_not_a_get() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;

    let (status, _) = harness.get("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
}

/// A panel that has never paired cannot mint, and saying so plainly is what
/// stops the operator hunting for the fault in GitHub or in the browser.
#[tokio::test]
async fn a_panel_without_a_daemon_credential_says_so() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let owner_id = harness.account_id("ada").await;
    harness
        .post(
            &format!("/panel/api/accounts/{owner_id}/approve"),
            Some(&owner),
        )
        .await;

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(body.contains("\"code\":\"unavailable\""), "{body}");
    assert!(body.contains("has not paired with the daemon"), "{body}");
}

/// Approval is read from the account on every request, not from the session,
/// so withdrawing it takes effect on the next attempt rather than whenever the
/// person next signs in.
#[tokio::test]
async fn a_revoke_stops_the_next_attempt_without_touching_the_session() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let grace = harness.sign_in("grace").await;
    let grace_id = harness.account_id("grace").await;

    harness
        .post(
            &format!("/panel/api/accounts/{grace_id}/approve"),
            Some(&owner),
        )
        .await;
    // Approved, so the panel is willing and only the absent daemon stops it.
    let (approved, _) = harness.post("/panel/api/pair-links", Some(&grace)).await;
    assert_ne!(approved, StatusCode::FORBIDDEN);

    harness
        .post(
            &format!("/panel/api/accounts/{grace_id}/revoke"),
            Some(&owner),
        )
        .await;

    let (revoked, body) = harness.post("/panel/api/pair-links", Some(&grace)).await;
    assert_eq!(revoked, StatusCode::FORBIDDEN, "{body}");
    // The session itself is untouched: they are still signed in, just no longer
    // allowed to generate a link.
    assert_eq!(
        harness.get("/panel/api/me", Some(&grace)).await.0,
        StatusCode::OK
    );
}
