#![cfg(target_os = "linux")]
#![allow(
    clippy::absolute_paths,
    reason = "the public ACME proof keeps system-bound collaborators explicit"
)]

#[path = "remote_daemon_public_acme/aftermarket.rs"]
mod aftermarket;
#[path = "remote_daemon_public_acme/aftermarket_http.rs"]
mod aftermarket_http;
#[path = "remote_daemon_public_acme/certificate.rs"]
mod certificate;
#[allow(
    dead_code,
    reason = "shared fake/public e2e client exposes constructors used by its sibling target"
)]
#[path = "remote_daemon_e2e/client.rs"]
mod client;
#[path = "remote_daemon_public_acme/config.rs"]
mod config;
#[path = "remote_daemon_public_acme/dns.rs"]
mod dns;
#[path = "remote_daemon_public_acme/process.rs"]
mod process;
#[path = "remote_daemon_public_acme/staging_roots.rs"]
mod staging_roots;
#[path = "remote_daemon_public_acme/visibility.rs"]
mod visibility;
#[path = "remote_daemon_public_acme/visibility_system.rs"]
mod visibility_system;

use std::process::id as process_id;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use aftermarket::LiveAftermarketPublicDnsApi;
use certificate::validate_verified_leaf_metadata;
use client::{RemoteCredentials, RemoteDaemonClient};
use config::{PublicAcmeChallenge, PublicAcmeConfig};
use dns::with_temporary_a_records;
use process::{PublicAcmeEnvironment, PublicAcmeProcess};
use serde_json::Value;
use staging_roots::LETS_ENCRYPT_STAGING_ROOTS_PEM;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires Linux, sudo setcap, live Aftermarket credentials, public DNS, and Let's Encrypt staging"]
async fn remote_daemon_public_acme_staging_proves_all_challenges() {
    let config = PublicAcmeConfig::from_environment().expect("public ACME proof configuration");
    let dns =
        LiveAftermarketPublicDnsApi::new_live(&config).expect("public ACME Aftermarket DNS client");
    let environment = PublicAcmeEnvironment::new().expect("public ACME process environment");
    let nonce = proof_nonce().expect("public ACME proof nonce");
    let cases = PublicAcmeChallenge::ALL
        .map(|challenge| (challenge, config.case_domain(challenge, &nonce)));
    let records = cases
        .iter()
        .map(|(_, domain)| (domain.clone(), config.ipv4))
        .collect::<Vec<_>>();

    with_temporary_a_records(&dns, &records, || async {
        for (challenge, domain) in &cases {
            run_public_acme_case(&environment, &config, domain, *challenge)
                .await
                .map_err(|error| {
                    format!(
                        "{} public ACME staging proof failed for {domain}: {error}",
                        challenge.cli_name()
                    )
                })?;
            println!(
                "{} public ACME staging proof passed for {domain}",
                challenge.cli_name()
            );
        }
        Ok(())
    })
    .await
    .unwrap_or_else(|error| panic!("public ACME staging proof failed: {error}"));
}

async fn run_public_acme_case(
    environment: &PublicAcmeEnvironment,
    config: &PublicAcmeConfig,
    domain: &str,
    challenge: PublicAcmeChallenge,
) -> Result<(), String> {
    let mut daemon = environment.spawn(config, domain, challenge)?;
    let client = RemoteDaemonClient::new(domain, 443, LETS_ENCRYPT_STAGING_ROOTS_PEM)?;
    wait_for_public_listener(&client, &mut daemon).await?;
    daemon.ensure_running()?;
    verify_public_transport(&daemon, &client, domain, challenge).await?;
    stop_public_daemon(&daemon, &client, challenge).await?;
    daemon.wait_for_exit().await
}

async fn verify_public_transport(
    daemon: &PublicAcmeProcess<'_>,
    client: &RemoteDaemonClient,
    domain: &str,
    challenge: PublicAcmeChallenge,
) -> Result<(), String> {
    let leaf = client.verified_leaf_certificate_der().await?;
    validate_verified_leaf_metadata(domain, &leaf)?;
    let operator_id = format!("public-{}-operator", challenge.cli_name());
    let operator = pair_client(daemon, client, "operator", &operator_id).await?;
    client.expect_health(&operator, 200).await?;
    client.expect_telemetry(&operator, 200).await?;
    client
        .expect_websocket_health_and_admin_denial(&operator)
        .await
}

async fn stop_public_daemon(
    daemon: &PublicAcmeProcess<'_>,
    client: &RemoteDaemonClient,
    challenge: PublicAcmeChallenge,
) -> Result<(), String> {
    let admin_id = format!("public-{}-admin", challenge.cli_name());
    let admin = pair_client(daemon, client, "admin", &admin_id).await?;
    client.expect_log_level_update(&admin, 200).await?;
    client.stop(&admin).await
}

async fn wait_for_public_listener(
    client: &RemoteDaemonClient,
    daemon: &mut PublicAcmeProcess<'_>,
) -> Result<(), String> {
    let deadline = tokio::time::Instant::now() + Duration::from_mins(12);
    loop {
        match client
            .wait_until_listening_for(Duration::from_secs(2))
            .await
        {
            Ok(()) => return Ok(()),
            Err(error) if tokio::time::Instant::now() < deadline => {
                daemon.ensure_running().map_err(|process_error| {
                    format!("{process_error}; last HTTPS readiness error: {error}")
                })?;
            }
            Err(error) => {
                return Err(format!(
                    "public HTTPS listener did not start: {error}; {}",
                    daemon.diagnostics()
                ));
            }
        }
    }
}

async fn pair_client(
    daemon: &PublicAcmeProcess<'_>,
    client: &RemoteDaemonClient,
    role: &str,
    client_id: &str,
) -> Result<RemoteCredentials, String> {
    let invitation = daemon.create_pairing(role)?;
    let code = required_string(&invitation, "code")?;
    let credentials = client.claim_pairing(code, client_id, role).await?;
    if credentials.role != role {
        return Err(format!(
            "public pairing role mismatch: expected {role}, received {}",
            credentials.role
        ));
    }
    Ok(credentials)
}

fn required_string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("public pairing response omitted {field}: {value}"))
}

fn proof_nonce() -> Result<String, String> {
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("read public ACME proof time: {error}"))?
        .as_secs();
    Ok(format!("{}-{epoch}", process_id()))
}
