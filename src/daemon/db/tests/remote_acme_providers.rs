use super::*;
use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider};

#[test]
fn remote_acme_state_persists_serve_config_for_issuance() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let config = remote_serve_config(RemoteDnsProvider::Cloudflare);

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
        .load_remote_acme_state()
        .expect("load remote acme state")
        .serve_config
        .expect("stored remote acme serve config");
    assert_eq!(loaded, *stored);
}

#[test]
fn remote_acme_state_roundtrips_aftermarket_provider() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let config = remote_serve_config(RemoteDnsProvider::Aftermarket);

    db.record_remote_acme_serve_config(&config, "2026-07-11T07:00:00Z")
        .expect("record Aftermarket config");

    let stored = db
        .load_remote_acme_state()
        .expect("load ACME state")
        .serve_config
        .expect("stored serve config");
    assert_eq!(
        stored.acme_dns_provider,
        Some(RemoteDnsProvider::Aftermarket)
    );
}

fn remote_serve_config(provider: RemoteDnsProvider) -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: " daemon.example.com ".to_string(),
        host: " 0.0.0.0 ".to_string(),
        https_port: 8443,
        http_port: 8080,
        acme_email: " ops@example.com ".to_string(),
        acme_challenge: RemoteAcmeChallenge::Dns,
        acme_dns_provider: Some(provider),
    }
}
