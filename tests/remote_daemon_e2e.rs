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
use process::{RemoteDaemonEnvironment, RemoteDaemonProcess};
use serde_json::Value;

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

    let viewer = pair_client(&daemon, &client, "viewer", "viewer-e2e").await?;
    client.expect_health(&viewer, 200).await?;
    client.expect_telemetry(&viewer, 403).await?;

    let operator = pair_client(&daemon, &client, "operator", "operator-e2e").await?;
    client.expect_telemetry(&operator, 200).await?;
    client.expect_log_level_update(&operator, 403).await?;
    client
        .expect_websocket_health_and_admin_denial(&operator)
        .await?;

    let admin = pair_client(&daemon, &client, "admin", "admin-e2e").await?;
    client.expect_log_level_update(&admin, 200).await?;

    daemon.revoke_client(&operator.client_id)?;
    client.expect_health(&operator, 401).await?;
    acme.assert_complete().await?;

    client.stop(&admin).await?;
    daemon.wait_for_exit().await?;
    acme.shutdown().await?;
    Ok(())
}

async fn pair_client(
    daemon: &RemoteDaemonProcess,
    client: &RemoteDaemonClient,
    role: &str,
    client_id: &str,
) -> Result<client::RemoteCredentials, String> {
    let invitation = daemon.create_pairing(role)?;
    let code = required_string(&invitation, "code")?;
    let credentials = client.claim_pairing(code, client_id, role).await?;
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
