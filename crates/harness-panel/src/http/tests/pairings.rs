//! Listing and withdrawing pairings, against a stub standing in for the daemon.
//!
//! The panel holds one broker credential for everybody who signs in, so the
//! daemon cannot tell one account from another and every question about whose
//! pairing this is gets answered here. These go through the whole path for that
//! reason: the stub replies to the same routes the daemon documents, so a field
//! or a status renamed on either side of the wire fails here rather than in
//! production.

use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::{StatusCode, header};
use chrono::{TimeZone, Utc};
use serde_json::Value;
use tower::ServiceExt;

use super::{Harness, router, session_cookie_name};
use crate::daemon_client::DaemonCredential;
use crate::store::pair_links::PairLinkRecord;

mod daemon_stub;

use daemon_stub::{Daemon, claimed, pairing, pairing_minted_by, stub_daemon};

/// A panel with a stored credential and a daemon that answers.
async fn ready(daemon: Arc<Mutex<Daemon>>) -> Harness {
    let endpoint = stub_daemon(daemon).await;
    let harness = Harness::with_daemon("ada", &endpoint).await;
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
    harness
}

/// File a link the panel minted for `login`, as the mint path would have.
async fn attribute(harness: &Harness, pairing_id: &str, login: &str) {
    let account_id = harness.account_id(login).await;
    let created_at = Utc
        .with_ymd_and_hms(2026, 7, 26, 10, 0, 0)
        .single()
        .expect("a valid timestamp");
    harness
        .state
        .store
        .record_pair_link(&PairLinkRecord {
            id: pairing_id.to_owned(),
            account_id,
            role: "operator".to_owned(),
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
        })
        .await
        .expect("record");
}

/// The whole point of the view for anyone but the owner: their own links, and
/// no sign that anybody else has any.
#[tokio::test]
async fn a_person_sees_only_the_pairings_they_generated() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![
            claimed("pair-1", "Ada's laptop"),
            pairing("pair-2", "pending"),
        ],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "grace").await;
    attribute(&harness, "pair-2", "ada").await;

    let (status, body) = harness.get("/panel/api/pairings", Some(&grace)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body.contains("pair-1"), "{body}");
    assert!(
        !body.contains("pair-2"),
        "another account's pairing must not appear: {body}"
    );
}

/// The owner's view is the one that covers everyone, and each row has to name
/// the account it belongs to or the owner cannot tell whose device they are
/// looking at.
#[tokio::test]
async fn the_owner_sees_every_pairing_and_whose_it_is() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![
            claimed("pair-1", "Ada's laptop"),
            pairing("pair-2", "pending"),
        ],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    attribute(&harness, "pair-1", "grace").await;
    attribute(&harness, "pair-2", "ada").await;
    let grace_id = harness.account_id("grace").await;

    let (status, body) = harness.get("/panel/api/pairings", Some(&owner)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let listed: Value = serde_json::from_str(&body).expect("a pairings body");
    let pairings = listed["pairings"].as_array().expect("an array");
    assert_eq!(pairings.len(), 2, "{body}");
    assert_eq!(pairings[0]["pairing_id"], "pair-1");
    assert_eq!(pairings[0]["account_id"], grace_id);
    assert_eq!(pairings[0]["device"]["display_name"], "Ada's laptop");
}

/// The real daemon scopes both inventory and revocation to the client id that
/// minted a pairing. Modeling that here makes a changed panel identity lose
/// visibility just as it would in production.
#[tokio::test]
async fn the_daemon_hides_pairings_minted_by_another_broker_identity() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![
            pairing("pair-current", "pending"),
            pairing_minted_by("pair-old", "active", "panel-replacement"),
        ],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    attribute(&harness, "pair-current", "ada").await;
    attribute(&harness, "pair-old", "ada").await;

    let (status, body) = harness.get("/panel/api/pairings", Some(&owner)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body.contains("pair-current"), "{body}");
    assert!(!body.contains("pair-old"), "{body}");
}

#[tokio::test]
async fn the_daemon_refuses_to_revoke_a_pairing_owned_by_another_broker_identity() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![pairing_minted_by("pair-old", "active", "panel-replacement")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-old", "grace").await;

    let (status, body) = harness
        .post("/panel/api/pairings/pair-old/revoke", Some(&grace))
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(daemon.lock().expect("stub lock").revoked.is_empty());
}

/// The panel records a link before it answers and shouts when it cannot, so a
/// pairing with no row is one that write missed. Nobody can be told it is
/// theirs, and showing it to whoever asks would put one person's device on
/// another's page — but hiding it from the owner too would leave a live
/// credential nobody can find.
#[tokio::test]
async fn a_pairing_the_panel_never_recorded_is_the_owners_alone() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-unrecorded", "Someone's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    let grace = harness.sign_in("grace").await;

    let (_, owner_body) = harness.get("/panel/api/pairings", Some(&owner)).await;
    let (_, grace_body) = harness.get("/panel/api/pairings", Some(&grace)).await;

    assert!(owner_body.contains("pair-unrecorded"), "{owner_body}");
    assert!(
        !owner_body.contains("account_id"),
        "the panel cannot name an owner it never recorded: {owner_body}"
    );
    assert!(!grace_body.contains("pair-unrecorded"), "{grace_body}");
}

/// The state comes from the daemon on every read rather than from what the
/// panel wrote down when it minted, which is what makes a pairing revoked on
/// the host read as revoked here.
#[tokio::test]
async fn a_pairing_revoked_outside_the_panel_reads_as_revoked() {
    let mut revoked = claimed("pair-1", "Ada's laptop");
    revoked.body["state"] = Value::String("revoked".to_owned());
    revoked.body["revoked_at"] = Value::String("2026-07-26T10:30:00Z".to_owned());
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![revoked],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    attribute(&harness, "pair-1", "ada").await;

    let (_, body) = harness.get("/panel/api/pairings", Some(&owner)).await;

    let listed: Value = serde_json::from_str(&body).expect("a pairings body");
    assert_eq!(listed["pairings"][0]["state"], "revoked");
    assert_eq!(listed["pairings"][0]["revoked_at"], "2026-07-26T10:30:00Z");
}

/// Cutting off one's own device is the thing this view exists to make possible
/// without shell access to the daemon's host.
#[tokio::test]
async fn a_person_can_unpair_their_own_device() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-1", "Grace's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "grace").await;

    let (status, body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&grace))
        .await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(body.contains("\"outcome\":\"device_revoked\""), "{body}");
    assert_eq!(daemon.lock().expect("stub lock").revoked, vec!["pair-1"]);
}

/// The daemon sees one broker credential for the whole panel, so this is the
/// only check standing between an approved account and everybody else's
/// devices.
#[tokio::test]
async fn unpairing_somebody_elses_device_never_reaches_the_daemon() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-1", "Ada's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "ada").await;

    let (status, body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&grace))
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(
        daemon.lock().expect("stub lock").revoked.is_empty(),
        "the refusal must happen before the daemon is asked"
    );
}

/// Answering these two apart would let any approved account walk the id space
/// and learn which pairings the panel has issued.
#[tokio::test]
async fn a_pairing_that_is_not_yours_answers_like_one_that_does_not_exist() {
    let daemon = Arc::new(Mutex::new(Daemon::default()));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "ada").await;

    let (someone_elses, elses_body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&grace))
        .await;
    let (nonexistent, nonexistent_body) = harness
        .post("/panel/api/pairings/pair-nowhere/revoke", Some(&grace))
        .await;

    assert_eq!(someone_elses, nonexistent);
    assert_eq!(elses_body, nonexistent_body);
}

/// A reservation is a slot the panel holds for a link the daemon never
/// confirmed. Its id is the panel's own spelling, and a caller that guessed it
/// must not be able to act on the row or learn that it is there.
#[tokio::test]
async fn a_reservation_id_is_not_a_pairing_anyone_can_revoke() {
    let daemon = Arc::new(Mutex::new(Daemon::default()));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    let grace_id = harness.account_id("grace").await;
    let created_at = Utc
        .with_ymd_and_hms(2026, 7, 26, 10, 0, 0)
        .single()
        .expect("a valid timestamp");
    harness
        .state
        .store
        .record_pair_link(&PairLinkRecord {
            id: "reservation:held".to_owned(),
            account_id: grace_id,
            role: "operator".to_owned(),
            created_at,
            expires_at: created_at + chrono::Duration::minutes(10),
        })
        .await
        .expect("record");

    let (status, body) = harness
        .post("/panel/api/pairings/reservation:held/revoke", Some(&grace))
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(daemon.lock().expect("stub lock").revoked.is_empty());
}

/// The owner is the one person who can cut off a device that is not theirs,
/// which is the whole reason the roster has an owner at all.
#[tokio::test]
async fn the_owner_can_unpair_anybody() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-1", "Grace's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    attribute(&harness, "pair-1", "grace").await;

    let (status, body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&owner))
        .await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(daemon.lock().expect("stub lock").revoked, vec!["pair-1"]);
}

/// The daemon's own refusal has to read the same as the panel's, or the
/// difference tells a caller that the panel believed the pairing was theirs.
#[tokio::test]
async fn a_daemon_refusal_reads_like_the_panels_own() {
    let daemon = Arc::new(Mutex::new(Daemon {
        refuse_revoke: true,
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "grace").await;

    let (refused, refused_body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&grace))
        .await;
    let (not_theirs, not_theirs_body) = harness
        .post("/panel/api/pairings/pair-nowhere/revoke", Some(&grace))
        .await;

    assert_eq!(refused, StatusCode::FORBIDDEN, "{refused_body}");
    assert_eq!(refused, not_theirs);
    assert_eq!(refused_body, not_theirs_body);
}

/// A daemon built before these routes, or a proxy that does not forward one,
/// answers with the same status a missing pairing does and nothing in the body.
/// Reporting that as the pairing being unavailable would send somebody hunting
/// for a permission problem while the real fault went unnamed, so it has to
/// read as the daemon failure it is.
#[tokio::test]
async fn a_daemon_that_does_not_serve_the_route_is_not_a_missing_pairing() {
    let daemon = Arc::new(Mutex::new(Daemon {
        unrouted_revoke: true,
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "grace").await;

    let (status, body) = harness
        .post("/panel/api/pairings/pair-1/revoke", Some(&grace))
        .await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR, "{body}");
    assert!(body.contains("\"code\":\"internal\""), "{body}");
}

/// `SameSite` cookies cross between sibling origins, so a state-changing
/// request needs more than the cookie to prove where it came from.
#[tokio::test]
async fn unpairing_from_another_origin_is_refused() {
    let daemon = Arc::new(Mutex::new(Daemon::default()));
    let harness = ready(Arc::clone(&daemon)).await;
    let grace = harness.sign_in("grace").await;
    attribute(&harness, "pair-1", "grace").await;

    let (status, body) = harness
        .post_from_origin(
            "/panel/api/pairings/pair-1/revoke",
            Some(&grace),
            Some("https://evil.example.com"),
        )
        .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(
        daemon.lock().expect("stub lock").revoked.is_empty(),
        "a cross-origin request must not reach the daemon"
    );
}

/// The daemon reads the panel's identity from one header and its token from
/// another. A rename on either side would leave the panel unauthenticated, and
/// nothing else in this file would notice.
#[tokio::test]
async fn the_stored_credential_is_replayed_on_both_headers() {
    let daemon = Arc::new(Mutex::new(Daemon::default()));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;

    harness.get("/panel/api/pairings", Some(&owner)).await;

    let daemon = daemon.lock().expect("stub lock");
    assert_eq!(daemon.client_id.as_deref(), Some("panel-1"));
    assert_eq!(daemon.authorization.as_deref(), Some("Bearer broker-token"));
}

/// This body names one person's devices and a 200 is heuristically cacheable,
/// so without the header a proxy between the daemon and the browser is free to
/// hand the owner's whole inventory to the next request that looks the same.
#[tokio::test]
async fn the_pairings_view_is_never_cached() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-1", "Ada's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;
    let owner = harness.sign_in("ada").await;
    let cookie = session_cookie_name(&harness.state);

    let response = router(harness.state.clone())
        .oneshot(
            Harness::request()
                .uri("/panel/api/pairings")
                .header(header::COOKIE, format!("{cookie}={owner}"))
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(header::CACHE_CONTROL)
            .and_then(|value| value.to_str().ok()),
        Some("no-store")
    );
}

/// Signing out has to close this view too, and an unauthenticated caller must
/// not learn that any pairing exists.
#[tokio::test]
async fn the_pairings_view_needs_a_session() {
    let daemon = Arc::new(Mutex::new(Daemon {
        pairings: vec![claimed("pair-1", "Ada's laptop")],
        ..Daemon::default()
    }));
    let harness = ready(Arc::clone(&daemon)).await;

    let (status, body) = harness.get("/panel/api/pairings", None).await;

    assert_eq!(status, StatusCode::UNAUTHORIZED, "{body}");
    assert!(!body.contains("pair-1"), "{body}");
}
