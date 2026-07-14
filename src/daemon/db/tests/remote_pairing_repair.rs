use super::*;
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;
use crate::daemon::remote_pairing::{
    RemotePairingClaimRequest, RemotePairingCode, RemotePairingRecord,
};

#[test]
fn remote_pairing_claim_replaces_existing_stable_client() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let old_token = "existing-stable-client-token";
    let registration = RemoteClientRegistration::new_for_tests(
        "stable-iphone",
        "Old iPhone",
        "watchos",
        RemoteRole::Viewer,
        &[],
        old_token,
        "2026-07-14T00:00:00Z",
    )
    .expect("existing client registration");
    db.register_remote_client(&registration)
        .expect("register existing client");

    let code = RemotePairingCode::from_value_for_tests("stable-client-repair-secret");
    let record = RemotePairingRecord::new_for_tests(
        "pairing-stable-client",
        RemoteRole::Operator,
        &[RemoteAccessScope::Read, RemoteAccessScope::Write],
        code.expose(),
        "2026-07-14T00:01:00Z",
        "2026-07-14T00:11:00Z",
    )
    .expect("pairing record");
    db.create_remote_pairing_code(&record, "audit-create-stable-client")
        .expect("create pairing");
    let claim = RemotePairingClaimRequest::new_for_tests(
        "daemon.example.com",
        "daemon.example.com",
        "stable-iphone",
        "Bart's iPhone",
        "ios",
        Some("203.0.113.50"),
        "audit-claim-stable-client",
    )
    .expect("claim request");

    let claimed = db
        .claim_remote_pairing_code(code.expose(), &claim, "2026-07-14T00:02:00Z")
        .expect("re-pair stable client");

    assert_eq!(claimed.client.client_id, "stable-iphone");
    assert_eq!(claimed.client.display_name, "Bart's iPhone");
    assert_eq!(claimed.client.platform, "ios");
    assert_eq!(claimed.client.role, RemoteRole::Operator);
    assert_eq!(
        claimed.client.scopes,
        vec![RemoteAccessScope::Read, RemoteAccessScope::Write]
    );
    assert_eq!(claimed.client.created_at, "2026-07-14T00:02:00Z");
    assert_eq!(
        claimed.client.rotated_at.as_deref(),
        Some("2026-07-14T00:02:00Z")
    );
    assert!(claimed.client.last_seen_at.is_none());
    assert!(claimed.client.revoked_at.is_none());
    assert!(
        db.verify_remote_client_token("stable-iphone", old_token)
            .expect("verify old token")
            .is_none(),
        "re-pairing must invalidate the previous credential"
    );
    assert!(
        db.verify_remote_client_token("stable-iphone", claimed.bearer_token.expose())
            .expect("verify replacement token")
            .is_some(),
        "replacement credential must authenticate"
    );
    assert_eq!(db.list_remote_clients().expect("list clients").len(), 1);
}
