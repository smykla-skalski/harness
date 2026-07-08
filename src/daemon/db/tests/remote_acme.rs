use super::*;

#[test]
fn remote_acme_state_status_hides_private_key_and_tracks_material() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'fp-1',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed acme state");

    let state = db.load_remote_acme_state().expect("load acme state");

    assert!(state.account_configured);
    assert_eq!(state.account_id.as_deref(), Some("acct-1"));
    assert!(state.certificate_configured);
    assert_eq!(state.certificate_fingerprint.as_deref(), Some("fp-1"));
    assert_eq!(state.renewal_status.as_str(), "succeeded");
    assert_eq!(state.renewal_error, None);
    assert_eq!(state.updated_at, "2026-06-21T15:00:00Z");
    assert!(
        !format!("{state:?}").contains("key-secret"),
        "ACME status debug output must not expose private key material"
    );
}

#[test]
fn remote_acme_renewal_failure_persists_redacted_report() {
    let db = DaemonDb::open_in_memory().expect("open db");

    db.record_remote_acme_renewal_failure(
        "dns token=remote-secret&retry=1 secret=nested-secret",
        "2026-06-21T15:01:00Z",
    )
    .expect("record renewal failure");

    let state = db.load_remote_acme_state().expect("load acme state");
    assert_eq!(state.renewal_status.as_str(), "failed");
    assert_eq!(
        state.renewal_error.as_deref(),
        Some("renewal failed: dns token=<redacted>&retry=1 secret=<redacted>")
    );
    assert_eq!(state.updated_at, "2026-06-21T15:01:00Z");
}
