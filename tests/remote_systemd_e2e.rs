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
#[path = "remote_systemd_e2e/candidates.rs"]
mod candidates;
#[path = "remote_systemd_e2e/cleanup.rs"]
mod cleanup;
#[path = "remote_daemon_e2e/client.rs"]
#[allow(
    dead_code,
    reason = "shared e2e client supports the broader daemon matrix"
)]
mod client;
#[path = "remote_systemd_e2e/crash_boundary.rs"]
mod crash_boundary;
#[path = "remote_systemd_e2e/database.rs"]
mod database;
#[path = "remote_systemd_e2e/evidence.rs"]
mod evidence;
#[path = "remote_systemd_e2e/host.rs"]
mod host;
#[path = "remote_systemd_e2e/ports.rs"]
mod ports;
#[path = "remote_systemd_e2e/systemd_assertions.rs"]
mod systemd_assertions;
#[path = "remote_systemd_e2e/upgrade.rs"]
mod upgrade;

use acme::{AcmeChallenge, AcmeChallengeConfig, FakeAcmeServer};
use client::{RemoteCredentials, RemoteDaemonClient};
use database::{
    DatabaseCanary, OPERATOR_MUTATED, OPERATOR_ORIGINAL, assert_live_database,
    establish_live_canary, mutate_live_canary,
};
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
    match run_systemd_case_with_host(&host).await {
        Ok(()) => Ok(()),
        Err(error) => match host.cleanup_strict() {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(format!(
                "{error}; strict systemd E2E cleanup also failed: {cleanup_error}"
            )),
        },
    }
}

async fn run_systemd_case_with_host(host: &RemoteSystemdHost) -> Result<(), String> {
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

    let (client, viewer, exposure) = install_and_pair(host, &acme).await?;
    let upgraded_binary_digest = prove_upgrade_flow(host, &client, &viewer).await?;
    prove_failed_upgrade(host, &client, &viewer, &upgraded_binary_digest).await?;
    prove_idempotent_install_and_restart(host, &client, &viewer).await?;

    let uninstall = host.uninstall()?;
    expect_bool(&uninstall, "/unit_removed", true)?;
    expect_bool(&uninstall, "/env_removed", true)?;
    println!("systemd security exposure: {exposure:.1}");
    acme.shutdown().await?;
    host.cleanup_strict()
}

async fn install_and_pair(
    host: &RemoteSystemdHost,
    acme: &FakeAcmeServer,
) -> Result<(RemoteDaemonClient, RemoteCredentials, f64), String> {
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
    Ok((client, viewer, exposure))
}

async fn prove_upgrade_flow(
    host: &RemoteSystemdHost,
    client: &RemoteDaemonClient,
    viewer: &RemoteCredentials,
) -> Result<String, String> {
    establish_live_canary(&host.state_path, OPERATOR_ORIGINAL)?;
    let original_binary_digest = host.installed_binary_digest()?;
    let (valid_upgrade_exit, valid_upgrade) = host.upgrade(host.valid_candidate_path())?;
    expect_exit_code(&valid_upgrade, valid_upgrade_exit, 0)?;
    expect_string(&valid_upgrade, "/outcome", "upgraded")?;
    expect_bool(&valid_upgrade, "/changed", true)?;
    expect_string(&valid_upgrade, "/health/status", "ready")?;
    host.assert_active_and_enabled()?;
    let upgraded_binary_digest = host.installed_binary_digest()?;
    if upgraded_binary_digest == original_binary_digest {
        return Err("valid systemd upgrade did not replace the installed binary".to_string());
    }
    expect_string(&valid_upgrade, "/candidate/sha256", &upgraded_binary_digest)?;
    host.assert_transaction_store_private()?;
    client.expect_health(viewer, 200).await?;
    mutate_live_canary(&host.state_path, OPERATOR_ORIGINAL, OPERATOR_MUTATED)?;

    prove_operator_rollback(
        host,
        client,
        viewer,
        &original_binary_digest,
        &upgraded_binary_digest,
        OPERATOR_ORIGINAL,
    )
    .await?;
    prove_operator_rollback(
        host,
        client,
        viewer,
        &upgraded_binary_digest,
        &original_binary_digest,
        OPERATOR_MUTATED,
    )
    .await?;

    host.prove_upgrade_coordinator_crash_recovery(&upgraded_binary_digest)?;
    host.assert_active_and_enabled()?;
    client.expect_health(viewer, 200).await?;
    Ok(upgraded_binary_digest)
}

async fn prove_failed_upgrade(
    host: &RemoteSystemdHost,
    client: &RemoteDaemonClient,
    viewer: &RemoteCredentials,
    upgraded_binary_digest: &str,
) -> Result<(), String> {
    let (failed_upgrade_exit, failed_upgrade) = host.upgrade(host.spoofed_candidate_path())?;
    expect_exit_code(&failed_upgrade, failed_upgrade_exit, 1)?;
    expect_string(&failed_upgrade, "/outcome", "rolled_back")?;
    expect_bool(&failed_upgrade, "/changed", false)?;
    expect_string(&failed_upgrade, "/previous/sha256", upgraded_binary_digest)?;
    expect_string(&failed_upgrade, "/health/status", "ready")?;
    expect_string(
        &failed_upgrade,
        "/health/observed_sha256",
        upgraded_binary_digest,
    )?;
    host.assert_candidate_database_corruption(&failed_upgrade)?;
    host.assert_active_and_enabled()?;
    let restored_binary_digest = host.installed_binary_digest()?;
    if restored_binary_digest != upgraded_binary_digest {
        return Err(format!(
            "automatic rollback restored binary digest {restored_binary_digest}, expected {upgraded_binary_digest}"
        ));
    }
    client.expect_health(viewer, 200).await
}

async fn prove_idempotent_install_and_restart(
    host: &RemoteSystemdHost,
    client: &RemoteDaemonClient,
    viewer: &RemoteCredentials,
) -> Result<(), String> {
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
    client.expect_health(viewer, 200).await
}

async fn prove_operator_rollback(
    host: &RemoteSystemdHost,
    client: &RemoteDaemonClient,
    viewer: &RemoteCredentials,
    restored_sha256: &str,
    displaced_sha256: &str,
    expected_database: DatabaseCanary,
) -> Result<(), String> {
    let (exit_code, report) = host.rollback()?;
    expect_exit_code(&report, exit_code, 0)?;
    expect_string(&report, "/operation", "rollback_systemd")?;
    expect_string(&report, "/outcome", "rolled_back")?;
    expect_string(&report, "/restored/sha256", restored_sha256)?;
    expect_string(&report, "/displaced/sha256", displaced_sha256)?;
    expect_string(&report, "/health/status", "ready")?;
    expect_string(&report, "/health/observed_sha256", restored_sha256)?;
    host.assert_active_and_enabled()?;
    let installed_sha256 = host.installed_binary_digest()?;
    if installed_sha256 != restored_sha256 {
        return Err(format!(
            "operator rollback installed {installed_sha256}, expected {restored_sha256}"
        ));
    }
    assert_live_database(
        &host.state_path,
        expected_database,
        "operator-restored live database",
    )?;
    client.expect_health(viewer, 200).await
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

fn expect_string(value: &serde_json::Value, pointer: &str, expected: &str) -> Result<(), String> {
    let actual = value
        .pointer(pointer)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| format!("systemd response omitted {pointer}: {value}"))?;
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "systemd response {pointer} was {actual}, expected {expected}: {value}"
        ))
    }
}

fn expect_exit_code(value: &serde_json::Value, actual: i32, expected: i32) -> Result<(), String> {
    if actual == expected {
        Ok(())
    } else {
        Err(format!(
            "systemd command exited with {actual}, expected {expected}: {value}"
        ))
    }
}

fn required_string<'a>(value: &'a serde_json::Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("pairing response omitted {field}: {value}"))
}
