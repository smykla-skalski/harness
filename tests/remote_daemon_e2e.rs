#![allow(
    clippy::absolute_paths,
    reason = "the isolated e2e binary keeps system-bound collaborators explicit"
)]
#![allow(
    clippy::cognitive_complexity,
    reason = "the top-level scenario keeps the complete remote contract visible"
)]

#[path = "remote_daemon_e2e/acme/mod.rs"]
mod acme;
#[path = "remote_daemon_e2e/client.rs"]
mod client;
#[path = "remote_daemon_e2e/process.rs"]
mod process;

use acme::{AcmeChallenge, AcmeChallengeConfig, FakeAcmeServer};
use client::RemoteDaemonClient;
use process::{AftermarketDnsEnvironment, RemoteDaemonEnvironment, RemoteDaemonProcess};
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType, IsCa, KeyPair,
    KeyUsagePurpose,
};
use serde_json::Value;
use std::env;
use std::time::Duration;

const DOMAIN: &str = "daemon.example.com";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "run with mise run remote-daemon:e2e"]
async fn remote_daemon_e2e_proves_acme_https_wss_pairing_and_revocation() {
    for challenge in AcmeChallenge::ALL {
        run_remote_daemon_case(challenge)
            .await
            .unwrap_or_else(|error| panic!("{} e2e failed: {error}", challenge.cli_name()));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires live Aftermarket credentials and authoritative DNS"]
async fn remote_daemon_e2e_cleans_aftermarket_dns_after_failed_issuance() {
    if env::var_os("HARNESS_TEST_AFTERMARKET_DOMAIN").is_none() {
        return;
    }
    run_aftermarket_failed_issuance_case()
        .await
        .unwrap_or_else(|error| panic!("live Aftermarket cleanup e2e failed: {error}"));
}

async fn run_aftermarket_failed_issuance_case() -> Result<(), String> {
    let domain = required_env("HARNESS_TEST_AFTERMARKET_DOMAIN")?;
    let zone_name = required_env("AFTERMARKET_ZONE_NAME")?;
    let api_key = required_env("AFTERMARKET_API_KEY")?;
    let api_secret = required_env("AFTERMARKET_API_SECRET")?;
    let environment = RemoteDaemonEnvironment::new(AcmeChallenge::Dns)?;
    let acme = FakeAcmeServer::start(AcmeChallengeConfig {
        challenge: AcmeChallenge::Dns,
        domain: domain.clone(),
        http_port: environment.http_port(),
        https_port: environment.https_port(),
        dns_log: environment.dns_log().to_path_buf(),
        ca_root: environment.acme_ca_root().to_path_buf(),
    })
    .await?;
    let aftermarket = AftermarketDnsEnvironment {
        zone_name: &zone_name,
        api_key: &api_key,
        api_secret: &api_secret,
        visibility_timeout_seconds: 900,
        visibility_poll_seconds: 2,
        visibility_stable_polls: 3,
    };
    let failure_timeout = aftermarket_failure_timeout(aftermarket.visibility_timeout_seconds);
    let mut daemon = RemoteDaemonProcess::spawn_aftermarket(
        &environment,
        &domain,
        acme.directory_url(),
        &aftermarket,
    )?;

    let diagnostics = daemon.wait_for_failure(failure_timeout).await?;
    let validation_error = acme.validation_error()?.ok_or_else(|| {
        format!("fake ACME server never received the ready DNS challenge; {diagnostics}")
    })?;

    if !validation_error.contains("DNS-01 hook") {
        return Err(format!(
            "fake ACME server failed before DNS validation: {validation_error}"
        ));
    }
    if diagnostics.contains("cleanup also failed") {
        return Err(format!(
            "Aftermarket cleanup failed after issuance error: {diagnostics}"
        ));
    }
    for secret in [&api_key, &api_secret] {
        if diagnostics.contains(secret) {
            return Err("remote daemon diagnostics exposed an Aftermarket secret".to_string());
        }
    }
    acme.shutdown().await
}

async fn run_remote_daemon_case(challenge: AcmeChallenge) -> Result<(), String> {
    let environment = RemoteDaemonEnvironment::new(challenge)?;
    let acme = FakeAcmeServer::start(AcmeChallengeConfig {
        challenge,
        domain: DOMAIN.to_string(),
        http_port: environment.http_port(),
        https_port: environment.https_port(),
        dns_log: environment.dns_log().to_path_buf(),
        ca_root: environment.acme_ca_root().to_path_buf(),
    })
    .await?;
    let mut daemon = RemoteDaemonProcess::spawn(&environment, challenge, acme.directory_url())?;
    let client = RemoteDaemonClient::new(DOMAIN, environment.https_port(), acme.ca_pem())?;

    client
        .wait_until_listening()
        .await
        .map_err(|error| format!("{error}; daemon output: {}", daemon.diagnostics()))?;
    daemon.ensure_running()?;
    expect_untrusted_ca_rejected(environment.https_port()).await?;

    let mut viewer = pair_client(&daemon, &client, "viewer", "viewer-e2e").await?;
    client.expect_health(&viewer, 200).await?;
    client.expect_oversized_http_body_rejected(&viewer).await?;
    client
        .expect_oversized_websocket_message_rejected(&viewer)
        .await?;
    client.expect_telemetry(&viewer, 403).await?;
    let rotated = client
        .expect_live_websocket_invalidation(&viewer, || daemon.rotate_client(&viewer.client_id))
        .await?;
    viewer.token = required_string(&rotated, "token")?.to_string();
    client.expect_health(&viewer, 200).await?;

    let operator = pair_client(&daemon, &client, "operator", "operator-e2e").await?;
    client.expect_telemetry(&operator, 200).await?;
    client.expect_log_level_update(&operator, 403).await?;
    client
        .expect_websocket_health_and_admin_denial(&operator)
        .await?;

    let admin = pair_client(&daemon, &client, "admin", "admin-e2e").await?;
    client.expect_log_level_update(&admin, 200).await?;

    client
        .expect_live_websocket_invalidation(&operator, || {
            daemon.revoke_client(&operator.client_id).map(|_| ())
        })
        .await?;
    client.expect_health(&operator, 401).await?;
    acme.assert_complete().await?;

    client.stop(&admin).await?;
    daemon.wait_for_exit().await?;
    acme.shutdown().await?;
    Ok(())
}

async fn expect_untrusted_ca_rejected(port: u16) -> Result<(), String> {
    let client = RemoteDaemonClient::new(DOMAIN, port, &unrelated_ca_pem()?)?;
    client
        .verified_leaf_certificate_der()
        .await
        .expect_err("untrusted certificate chain must fail");
    Ok(())
}

fn unrelated_ca_pem() -> Result<String, String> {
    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, "Harness Untrusted E2E CA");
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
    ];
    CertifiedIssuer::self_signed(
        params,
        KeyPair::generate().map_err(|error| format!("generate untrusted CA key: {error}"))?,
    )
    .map(|issuer| issuer.pem())
    .map_err(|error| format!("generate untrusted CA certificate: {error}"))
}

fn aftermarket_failure_timeout(visibility_timeout_seconds: u64) -> Duration {
    Duration::from_secs(
        visibility_timeout_seconds
            .saturating_mul(2)
            .saturating_add(120),
    )
}

#[test]
fn aftermarket_failure_timeout_covers_presentation_and_cleanup_windows() {
    assert_eq!(aftermarket_failure_timeout(900), Duration::from_mins(32));
}

async fn pair_client(
    daemon: &RemoteDaemonProcess,
    client: &RemoteDaemonClient,
    role: &str,
    client_id: &str,
) -> Result<client::RemoteCredentials, String> {
    let invitation = daemon.create_pairing(role)?;
    let pairing_id = required_string(&invitation, "pairing_id")?;
    let code = required_string(&invitation, "code")?;
    client.expect_pairing_status(pairing_id, "pending").await?;
    let credentials = client.claim_pairing(code, client_id, role).await?;
    client.expect_pairing_status(pairing_id, "claimed").await?;
    if credentials.role != role {
        return Err(format!(
            "pairing role mismatch: expected {role}, received {}",
            credentials.role
        ));
    }
    Ok(credentials)
}

fn required_string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("pairing response omitted {field}: {value}"))
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("live Aftermarket e2e requires {name}"))
}
