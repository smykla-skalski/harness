use super::*;
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig};
use crate::daemon::remote_acme::build_remote_acme_runtime_plan;

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
fn remote_acme_runtime_state_loads_certificate_material_for_serve() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed acme runtime state");

    let state = db
        .load_remote_acme_runtime_state()
        .expect("load acme runtime state");
    let plan = build_remote_acme_runtime_plan(&remote_serve_config(), &state)
        .expect("runtime state should plan remote TLS serve");

    assert_eq!(plan.public_https_origin(), "https://daemon.example.com");
    assert!(plan.certificate().has_material());
    assert_ne!(plan.certificate().fingerprint(), "stored-fp");
}

#[test]
fn remote_acme_runtime_state_preserves_account_only_failure() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = NULL,
                 private_key_pem = NULL,
                 certificate_fingerprint = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed account-only acme state");

    let state = db
        .load_remote_acme_runtime_state()
        .expect("load acme runtime state");
    let error = build_remote_acme_runtime_plan(&remote_serve_config(), &state)
        .expect_err("account-only state should fail without TLS material");

    assert!(error.to_string().contains("persisted TLS certificate"));
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

fn remote_serve_config() -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: "daemon.example.com".to_string(),
        host: "0.0.0.0".to_string(),
        https_port: 443,
        http_port: 80,
        acme_email: "ops@example.com".to_string(),
        acme_challenge: RemoteAcmeChallenge::TlsAlpn,
        acme_dns_provider: None,
    }
}
