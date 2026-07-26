//! Refusing a link the daemon issued under a role the panel did not ask for.
//!
//! The panel picks the role from its own allow-list, but only the daemon knows
//! what a code actually grants. When the two disagree the code is withheld and
//! withdrawn, and these cover both halves of that, including the case where the
//! withdrawal itself does not land.

use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use chrono::Utc;

use super::{Harness, Seen, mint_only_daemon, ready};
use crate::daemon_client::DaemonCredential;

/// The allow-list decides what the panel may ask for, but the daemon decides
/// what the code grants. If a misconfigured endpoint answers with more than was
/// asked for, showing it would hand out authority the owner never approved.
///
/// Withholding the code is not enough on its own: the link is minted and stays
/// claimable for its whole lifetime by anyone who reaches the daemon another
/// way, so the panel spends its `pair_manage` scope withdrawing it.
#[tokio::test]
async fn a_link_of_the_wrong_role_is_withheld_and_withdrawn() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (harness, owner) = ready(Arc::clone(&seen)).await;
    seen.lock().expect("stub lock").granted_role = Some("admin".to_owned());

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    assert!(
        !body.contains("harness://pair"),
        "the code must not reach the caller: {body}"
    );
    assert_eq!(
        seen.lock().expect("stub lock").withdrawn,
        vec!["pair-1"],
        "a code nobody may see must not be left claimable"
    );
    // Still written down, because the daemon minted it and an operator needs
    // the row to reconcile against the daemon whether or not the withdrawal
    // landed.
    let recorded = harness
        .state
        .store
        .pair_links_for_account(&harness.account_id("ada").await)
        .await
        .expect("records");
    assert_eq!(recorded.len(), 1, "{recorded:?}");
    assert_eq!(recorded[0].role, "admin");
}

/// The withdrawal is a second call to a daemon that has just behaved
/// unexpectedly, so it cannot be the thing the refusal depends on. A daemon
/// that will not take it back must still not have its code shown to anyone.
#[tokio::test]
async fn a_wrong_role_link_is_still_withheld_when_it_cannot_be_withdrawn() {
    let seen = Arc::new(Mutex::new(Seen::default()));
    // A stub that answers the mint route and nothing else, so the withdrawal
    // reaches a 404 the way an older daemon would answer it.
    let endpoint = mint_only_daemon(Arc::clone(&seen)).await;
    let harness = Harness::with_daemon("ada", &endpoint).await;
    let owner = harness.sign_in("ada").await;
    let owner_id = harness.account_id("ada").await;
    harness
        .post(
            &format!("/panel/api/accounts/{owner_id}/approve"),
            Some(&owner),
        )
        .await;
    harness
        .state
        .store
        .store_daemon_credential(
            &DaemonCredential {
                client_id: "panel-1".to_owned(),
                token: "broker-token".to_owned(),
                role: "pairing_broker".to_owned(),
            },
            Utc::now(),
        )
        .await
        .expect("credential");
    seen.lock().expect("stub lock").granted_role = Some("admin".to_owned());

    let (status, body) = harness.post("/panel/api/pair-links", Some(&owner)).await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    assert!(
        !body.contains("harness://pair"),
        "the code must not reach the caller: {body}"
    );
}
