use super::*;
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig};
use crate::daemon::remote_acme::{
    RemoteAcmeAccountCredentials, RemoteCertificateBundle, build_remote_acme_runtime_plan,
};

#[test]
fn remote_acme_state_status_hides_private_key_and_tracks_material() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-1","key_pkcs8":"account-key-secret"}',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'fp-1',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1"#,
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
fn remote_acme_serve_config_rejects_blank_host_before_persisting() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let mut config = remote_serve_config();
    config.host = "   ".to_string();

    let error = db
        .record_remote_acme_serve_config(&config, "2026-06-21T15:03:00Z")
        .expect_err("blank host should not be persisted");

    assert!(error.to_string().contains("bind host"));
    let state = db.load_remote_acme_state().expect("load acme state");
    assert_eq!(state.serve_config, None);
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
    assert_eq!(
        db.load_remote_acme_state()
            .expect("load migrated acme state")
            .serve_config,
        None
    );
}

#[test]
fn repairs_partially_applied_v28_remote_acme_config_columns() {
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
                     updated_at              TEXT NOT NULL,
                     domain                  TEXT
                 ) WITHOUT ROWID;
                 INSERT INTO remote_acme_state_v27 (
                     singleton, account_id, certificate_pem, private_key_pem,
                     certificate_fingerprint, renewal_status, renewal_error, updated_at, domain
                 )
                 SELECT singleton, account_id, certificate_pem, private_key_pem,
                        certificate_fingerprint, renewal_status, renewal_error, updated_at,
                        'daemon.example.com'
                 FROM remote_acme_state;
                 DROP TABLE remote_acme_state;
                 ALTER TABLE remote_acme_state_v27 RENAME TO remote_acme_state;
                 UPDATE schema_meta SET value = '27' WHERE key = 'version';",
            )
            .expect("simulate partial v28 remote acme state");
    }

    let db = DaemonDb::open(&path).expect("open repaired db");

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
}

#[test]
fn remote_acme_runtime_state_loads_certificate_material_for_serve() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-1","key_pkcs8":"account-key-secret"}',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 renewal_status = 'succeeded',
                 renewal_error = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1"#,
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
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-1","key_pkcs8":"account-key-secret"}',
                 certificate_pem = NULL,
                 private_key_pem = NULL,
                 certificate_fingerprint = NULL,
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1"#,
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
fn remote_acme_runtime_state_rejects_legacy_account_without_credentials() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            "UPDATE remote_acme_state
             SET account_id = 'legacy-account-id',
                 account_credentials_json = NULL,
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 updated_at = '2026-07-09T18:00:00Z'
             WHERE singleton = 1",
            [],
        )
        .expect("seed legacy acme runtime state");

    let state = db
        .load_remote_acme_runtime_state()
        .expect("load legacy acme runtime state");
    let error = build_remote_acme_runtime_plan(&remote_serve_config(), &state)
        .expect_err("legacy account id must not authorize remote TLS startup");

    assert!(error.to_string().contains("persisted ACME state"));
}

#[test]
fn remote_acme_runtime_state_rejects_mismatched_account_credentials() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.conn
        .execute(
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-2","key_pkcs8":"account-key-secret"}',
                 certificate_pem = 'cert-pem',
                 private_key_pem = 'key-secret',
                 certificate_fingerprint = 'stored-fp',
                 updated_at = '2026-07-09T18:00:00Z'
             WHERE singleton = 1"#,
            [],
        )
        .expect("seed mismatched acme runtime state");

    let error = db
        .load_remote_acme_runtime_state()
        .expect_err("mismatched account credentials must fail closed");

    assert!(error.to_string().contains("account id"));
    assert!(!error.to_string().contains("account-key-secret"));
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
            r#"UPDATE remote_acme_state
             SET account_id = 'acct-1',
                 account_credentials_json = '{"id":"acct-1","key_pkcs8":"account-key-secret"}',
                 certificate_pem = 'old-cert',
                 private_key_pem = 'old-key',
                 certificate_fingerprint = 'old-fp',
                 renewal_status = 'failed',
                 renewal_error = 'renewal failed: old error',
                 updated_at = '2026-06-21T15:00:00Z'
             WHERE singleton = 1"#,
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

#[test]
fn remote_acme_account_credentials_persist_without_secret_projection() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let account = RemoteAcmeAccountCredentials::new(
        "https://acme.test/acct/1",
        r#"{"id":"https://acme.test/acct/1","key_pkcs8":"account-key-secret"}"#,
    )
    .expect("valid account credentials");

    db.record_remote_acme_account(&account, "2026-07-09T18:00:00Z")
        .expect("record account credentials");

    let issuance = db
        .load_remote_acme_issuance_state()
        .expect("load issuance state");
    let stored = issuance
        .account
        .as_ref()
        .expect("stored account credentials");
    assert_eq!(stored.account_id(), "https://acme.test/acct/1");
    assert_eq!(stored.serialized(), account.serialized());
    assert!(!format!("{issuance:?}").contains("account-key-secret"));

    let status = db.load_remote_acme_state().expect("load safe status");
    assert!(status.account_configured);
    assert_eq!(
        status.account_id.as_deref(),
        Some("https://acme.test/acct/1")
    );
    assert!(!format!("{status:?}").contains("account-key-secret"));
}

#[test]
fn migrates_v28_remote_acme_state_to_account_credentials() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        db.conn
            .execute(
                "ALTER TABLE remote_acme_state DROP COLUMN account_credentials_json",
                [],
            )
            .expect("remove v29 account credentials column");
        db.conn
            .execute(
                "UPDATE schema_meta SET value = '28' WHERE key = 'version'",
                [],
            )
            .expect("stamp v28 schema");
    }

    let db = DaemonDb::open(&path).expect("open migrated db");

    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);
    let count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('remote_acme_state') \
             WHERE name = 'account_credentials_json'",
            [],
            |row| row.get(0),
        )
        .expect("query account credentials column");
    assert_eq!(count, 1);
}

#[test]
fn repairs_partially_applied_v29_account_credentials_column() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("open current db");
        db.conn
            .execute(
                "UPDATE schema_meta SET value = '28' WHERE key = 'version'",
                [],
            )
            .expect("simulate partial v29 migration");
    }

    let db = DaemonDb::open(&path).expect("open repaired db");

    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);
    let count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('remote_acme_state') \
             WHERE name = 'account_credentials_json'",
            [],
            |row| row.get(0),
        )
        .expect("query account credentials column");
    assert_eq!(count, 1);
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
