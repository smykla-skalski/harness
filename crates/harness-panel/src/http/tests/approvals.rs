//! Granting and withdrawing the ability to pair, at the router.

use axum::http::StatusCode;

use super::Harness;

/// Everyone starts unable to pair, including whoever signed in a moment ago,
/// so an account that appears while the owner is away cannot mint links.
#[tokio::test]
async fn a_new_account_reports_that_it_cannot_pair() {
    let harness = Harness::new("ada").await;
    let token = harness.sign_in("grace").await;

    let (status, body) = harness.get("/panel/api/me", Some(&token)).await;

    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"can_pair\":false"), "{body}");
}

#[tokio::test]
async fn the_owner_can_grant_and_withdraw_the_ability_to_pair() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let grace = harness.sign_in("grace").await;
    let grace_id = harness.account_id("grace").await;

    let (status, body) = harness
        .post(
            &format!("/panel/api/accounts/{grace_id}/approve"),
            Some(&owner),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"can_pair\":true"), "{body}");
    assert!(
        harness
            .get("/panel/api/me", Some(&grace))
            .await
            .1
            .contains("\"can_pair\":true")
    );

    let (status, body) = harness
        .post(
            &format!("/panel/api/accounts/{grace_id}/revoke"),
            Some(&owner),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("\"can_pair\":false"), "{body}");
    assert!(
        harness
            .get("/panel/api/me", Some(&grace))
            .await
            .1
            .contains("\"can_pair\":false")
    );
}

/// Approval is the owner's decision alone. Anyone able to approve themselves
/// would make the whole gate decorative.
#[tokio::test]
async fn nobody_but_the_owner_can_decide_an_approval() {
    let harness = Harness::new("ada").await;
    let grace = harness.sign_in("grace").await;
    let grace_id = harness.account_id("grace").await;

    for route in ["approve", "revoke"] {
        let path = format!("/panel/api/accounts/{grace_id}/{route}");

        let (signed_in, body) = harness.post(&path, Some(&grace)).await;
        assert_eq!(signed_in, StatusCode::FORBIDDEN, "{route}");
        assert!(body.contains("\"code\":\"forbidden\""), "{body}");

        let (anonymous, _) = harness.post(&path, None).await;
        assert_eq!(anonymous, StatusCode::UNAUTHORIZED, "{route}");
    }

    assert!(
        harness
            .get("/panel/api/me", Some(&grace))
            .await
            .1
            .contains("\"can_pair\":false")
    );
}

/// The owner's page can name an account that has since gone. Answering as
/// though it worked would tell them a decision took effect that did not.
#[tokio::test]
async fn deciding_about_an_unknown_account_is_a_404() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;

    let (status, body) = harness
        .post("/panel/api/accounts/absent/approve", Some(&owner))
        .await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body.contains("\"code\":\"not_found\""), "{body}");
}

/// Approving is a state change, so a plain link or an image tag must not carry
/// it out.
#[tokio::test]
async fn approving_is_not_a_get() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let grace_id = harness.account_id("grace").await;

    let (status, _) = harness
        .get(
            &format!("/panel/api/accounts/{grace_id}/approve"),
            Some(&owner),
        )
        .await;

    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
}

/// `SameSite` cookies cross between sibling origins, so the owner being signed
/// in is not enough to authorize a mutation.
#[tokio::test]
async fn another_origin_cannot_decide_an_approval() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let grace_id = harness.account_id("grace").await;
    let path = format!("/panel/api/accounts/{grace_id}/approve");

    for origin in [None, Some("https://attacker.example.com")] {
        let (status, body) = harness.post_from_origin(&path, Some(&owner), origin).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    }

    let grace = harness.sign_in("grace").await;
    assert!(
        harness
            .get("/panel/api/me", Some(&grace))
            .await
            .1
            .contains("\"can_pair\":false")
    );
}

/// The owner is a person too, and has to approve themselves like anyone else
/// rather than being quietly exempt.
#[tokio::test]
async fn the_owner_is_not_approved_by_owning_the_panel() {
    let harness = Harness::new("ada").await;
    let owner = harness.sign_in("ada").await;
    let owner_id = harness.account_id("ada").await;

    assert!(
        harness
            .get("/panel/api/me", Some(&owner))
            .await
            .1
            .contains("\"can_pair\":false")
    );

    harness
        .post(
            &format!("/panel/api/accounts/{owner_id}/approve"),
            Some(&owner),
        )
        .await;

    assert!(
        harness
            .get("/panel/api/me", Some(&owner))
            .await
            .1
            .contains("\"can_pair\":true")
    );
}
