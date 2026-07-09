use super::*;
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider};
use crate::daemon::remote_acme::{RemoteCertificateBundle, build_remote_acme_runtime_plan};

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
fn remote_acme_state_persists_serve_config_for_issuance() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let config = RemoteDaemonServeConfig {
        domain: " daemon.example.com ".to_string(),
        host: " 0.0.0.0 ".to_string(),
        https_port: 8443,
        http_port: 8080,
        acme_email: " ops@example.com ".to_string(),
        acme_challenge: RemoteAcmeChallenge::Dns,
        acme_dns_provider: Some(RemoteDnsProvider::Cloudflare),
    };

    db.record_remote_acme_serve_config(&config, "2026-06-21T15:03:00Z")
        .expect("record remote acme serve config");

    let state = db.load_remote_acme_state().expect("load acme state");
    let stored = state
        .serve_config
        .as_ref()
        .expect("serve config should be stored");
    assert_eq!(stored.domain, "daemon.example.com");
    assert_eq!(stored.host, "0.0.0.0");
    assert_eq!(stored.https_port, 8443);
    assert_eq!(stored.http_port, 8080);
    assert_eq!(stored.acme_email, "ops@example.com");
    assert_eq!(stored.acme_challenge, RemoteAcmeChallenge::Dns);
    assert_eq!(
        stored.acme_dns_provider,
        Some(RemoteDnsProvider::Cloudflare)
    );
    assert_eq!(state.updated_at, "2026-06-21T15:03:00Z");

    let loaded = db
        .load_remote_acme_serve_config()
        .expect("load remote acme serve config")
        .expect("stored remote acme serve config");
    assert_eq!(loaded, *stored);
}

#[test]
fn migrates_v27_remote_acme_state_to_serve_config_columns() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        db.conn
            .execute_batch(
                "CREATE TABLE remote_acme_state_v27 (
                     singleton               INTEGER PRIMARY KEY CHECK (singleton = 1),
                     account_id              TEXT,
                     certificate_pem         TEXT,
                     private_key_pem         TEXT,
                     certificate_fingerprint TEXT,
                     renewal_status          TEXT NOT NULL DEFAULT 'unknown',
                     renewal_error           TEXT,
                     updated_at              TEXT NOT NULL
                 ) WITHOUT ROWID;
                 INSERT INTO remote_acme_state_v27 (
                     singleton, account_id, certificate_pem, private_key_pem,
                     certificate_fingerprint, renewal_status, renewal_error, updated_at
                 )
                 SELECT singleton, account_id, certificate_pem, private_key_pem,
                        certificate_fingerprint, renewal_status, renewal_error, updated_at
                 FROM remote_acme_state;
                 DROP TABLE remote_acme_state;
                 ALTER TABLE remote_acme_state_v27 RENAME TO remote_acme_state;
                 UPDATE schema_meta SET value = '27' WHERE key = 'version';",
            )
            .expect("downgrade remote acme state");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");

    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);
    for column in [
        "domain",
        "host",
        "https_port",
        "http_port",
        "acme_email",
        "acme_challenge",
        "acme_dns_provider",
    ] {
        let count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('remote_acme_state') WHERE name = ?1",
                [column],
                |row| row.get(0),
            )
            .expect("query remote acme column");
        assert_eq!(count, 1, "missing remote_acme_state column: {column}");
    }
    assert!(
        db.load_remote_acme_serve_config()
            .expect("load migrated serve config")
            .is_none()
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

#[test]
fn remote_acme_renewal_success_persists_certificate_and_clears_error() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 certificate_pem = 'old-cert',
                 private_key_pem = 'old-key',
                 certificate_fingerprint = 'old-fp',
                 renewal_status = 'failed',
                 renewal_error = 'renewal failed: old error',
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed failed acme state");
    let bundle = RemoteCertificateBundle::new_for_tests("new-cert-pem", "new-key-secret");

    db.record_remote_acme_renewal_success(&bundle, "2026-06-21T15:02:00Z")
        .expect("record renewal success");

    let state = db.load_remote_acme_state().expect("load acme state");
    assert_eq!(state.renewal_status.as_str(), "succeeded");
    assert_eq!(state.renewal_error, None);
    assert_eq!(
        state.certificate_fingerprint.as_deref(),
        Some(bundle.fingerprint())
    );
    assert_eq!(state.updated_at, "2026-06-21T15:02:00Z");

    let runtime_state = db
        .load_remote_acme_runtime_state()
        .expect("load acme runtime state");
    let runtime_plan = build_remote_acme_runtime_plan(&remote_serve_config(), &runtime_state)
        .expect("renewed certificate should be usable for remote serve");
    assert_eq!(
        runtime_plan.certificate().fingerprint(),
        bundle.fingerprint()
    );
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
