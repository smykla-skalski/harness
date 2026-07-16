#![cfg(target_os = "linux")]
#![allow(
    clippy::absolute_paths,
    reason = "the Linux systemd proof keeps host integrations explicit"
)]

#[path = "remote_daemon_e2e/acme/mod.rs"]
#[allow(
    dead_code,
    reason = "shared e2e helper supports additional challenge cases"
)]
mod acme;
#[path = "remote_daemon_e2e/client.rs"]
#[allow(
    dead_code,
    reason = "shared e2e client supports the broader daemon matrix"
)]
mod client;
#[path = "remote_systemd_e2e/host.rs"]
mod host;
#[path = "remote_systemd_e2e/ports.rs"]
mod ports;

use acme::{AcmeChallenge, AcmeChallengeConfig, FakeAcmeServer};
use client::RemoteDaemonClient;
use host::RemoteSystemdHost;

const DOMAIN: &str = "daemon.systemd.test";
// Internet sockets and CAP_NET_BIND_SERVICE account for the remaining exposure.
const SECURITY_THRESHOLD: f64 = 1.4;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires Linux systemd and passwordless sudo"]
async fn remote_systemd_e2e_proves_lifecycle_and_effective_security() {
    run_systemd_case()
        .await
        .unwrap_or_else(|error| panic!("remote systemd e2e failed: {error}"));
}

async fn run_systemd_case() -> Result<(), String> {
    let host = RemoteSystemdHost::new(DOMAIN)?;
    host.assert_prerequisites()?;
    let acme = FakeAcmeServer::start(AcmeChallengeConfig {
        challenge: AcmeChallenge::TlsAlpn,
        domain: DOMAIN.to_string(),
        http_port: host.http_port(),
        https_port: host.https_port(),
        dns_log: host.dns_log().to_path_buf(),
        ca_root: host.fake_ca_root().to_path_buf(),
        certificate_validity_days: 90,
    })
    .await?;
    host.prepare(acme.directory_url(), acme.ca_pem())?;

    let first_install = host.install()?;
    expect_bool(&first_install, "/applied/unit_written", true)?;
    expect_bool(&first_install, "/applied/env_written", false)?;
    host.assert_active_and_enabled()?;
    let client = RemoteDaemonClient::new(DOMAIN, host.https_port(), acme.ca_pem())?;
    client
        .wait_until_listening()
        .await
        .map_err(|error| host.with_diagnostics(error))?;
    acme.assert_complete().await?;

    let exposure = host.security_exposure(SECURITY_THRESHOLD)?;
    host.assert_effective_sandbox()?;
    let invitation = host.create_pairing("viewer")?;
    let code = required_string(&invitation, "code")?;
    let viewer = client
        .claim_pairing(code, "systemd-viewer", "viewer")
        .await?;
    client.expect_health(&viewer, 200).await?;

    let first_pid = host.main_pid()?;
    let env_digest = host.environment_digest()?;
    let second_install = host.install()?;
    expect_bool(&second_install, "/applied/unit_written", false)?;
    expect_bool(&second_install, "/applied/env_written", false)?;
    if host.main_pid()? != first_pid {
        return Err("idempotent install restarted the active service".to_string());
    }
    if host.environment_digest()? != env_digest {
        return Err("idempotent install changed the pre-provisioned environment".to_string());
    }

    host.assert_cli_status()?;
    host.restart()?;
    client
        .wait_until_listening()
        .await
        .map_err(|error| host.with_diagnostics(error))?;
    let restarted_pid = host.main_pid()?;
    if restarted_pid == first_pid {
        return Err("systemd restart did not replace the daemon process".to_string());
    }
    client.expect_health(&viewer, 200).await?;

    let uninstall = host.uninstall()?;
    expect_bool(&uninstall, "/unit_removed", true)?;
    expect_bool(&uninstall, "/env_removed", true)?;
    host.assert_uninstalled()?;
    println!("systemd security exposure: {exposure:.1}");
    acme.shutdown().await
}

fn expect_bool(value: &serde_json::Value, pointer: &str, expected: bool) -> Result<(), String> {
    let actual = value
        .pointer(pointer)
        .and_then(serde_json::Value::as_bool)
        .ok_or_else(|| format!("systemd response omitted {pointer}: {value}"))?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "systemd response {pointer} was {actual}, expected {expected}: {value}"
        ))
    }
}

fn required_string<'a>(value: &'a serde_json::Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("pairing response omitted {field}: {value}"))
}
