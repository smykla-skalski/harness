use std::env;
use std::path::PathBuf;
use std::process::Command;

use tempfile::tempdir;

use super::support::{
    FakeGrafanaServer, GRAFANA_ADMIN_PASSWORD, GRAFANA_ADMIN_USER, GRAFANA_SERVICE_ACCOUNT_ID,
    STALE_TOKEN, expected_basic_admin_auth,
};

fn write_monitor_only_shared_config(
    repo: &PathBuf,
    fake_grafana_url: &str,
    home: &PathBuf,
    xdg_config_home: &PathBuf,
) -> PathBuf {
    let monitor_data_home = home
        .join("Library")
        .join("Group Containers")
        .join("Q498EB36N4.io.harnessmonitor");
    let config_output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--write-shared-config-fixture")
        .arg("false")
        .current_dir(repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", xdg_config_home)
        .env("XDG_DATA_HOME", &monitor_data_home)
        .env("HARNESS_GRAFANA_URL", fake_grafana_url)
        .output()
        .expect("write shared config fixture");
    assert!(
        config_output.status.success(),
        "shared config helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&config_output.stdout),
        String::from_utf8_lossy(&config_output.stderr)
    );
    let runtime_config_path = home
        .join("Library")
        .join("Application Support")
        .join("harness/observability/config.json");
    assert!(
        !runtime_config_path.exists(),
        "expected runtime config to be absent for regression setup"
    );
    let monitor_config_path = monitor_data_home.join("harness/observability/config.json");
    assert!(
        monitor_config_path.exists(),
        "expected monitor config to exist for regression setup"
    );
    monitor_config_path
}

#[test]
fn observability_refreshes_stale_grafana_token_after_stack_recreation() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");

    let config_output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--write-shared-config-fixture")
        .arg("false")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .env("HARNESS_GRAFANA_URL", &fake_grafana.base_url)
        .output()
        .expect("write shared config fixture");
    assert!(
        config_output.status.success(),
        "shared config helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&config_output.stdout),
        String::from_utf8_lossy(&config_output.stderr)
    );
    let token_path = xdg_config_home
        .join("harness/observability")
        .join("grafana-mcp.token");
    std::fs::create_dir_all(token_path.parent().expect("token parent")).expect("create token dir");
    std::fs::write(&token_path, STALE_TOKEN).expect("write stale token");

    let refresh_run = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--refresh-grafana-mcp-token-fixture")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .output()
        .expect("run token refresh helper");
    assert!(
        refresh_run.status.success(),
        "token refresh helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&refresh_run.stdout),
        String::from_utf8_lossy(&refresh_run.stderr)
    );
    assert_eq!(
        std::fs::read_to_string(&token_path).expect("read rotated token"),
        "fresh-token-1"
    );
    assert_eq!(fake_grafana.issued_token_count(), 1);

    let requests = fake_grafana.requests();
    assert!(
        requests.iter().any(|request| {
            request.method == "GET"
                && request.path == "/api/search"
                && request.authorization.as_deref() == Some(&format!("Bearer {STALE_TOKEN}"))
        }),
        "expected stale token validation request, got: {requests:?}"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == "GET"
                && request.path == "/api/serviceaccounts/search"
                && request.authorization.as_deref() == Some(expected_basic_admin_auth().as_str())
        }),
        "expected basic-auth service account lookup, got: {requests:?}"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == "POST"
                && request.path == "/api/serviceaccounts"
                && request.authorization.as_deref() == Some(expected_basic_admin_auth().as_str())
        }),
        "expected service account creation, got: {requests:?}"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == "POST"
                && request.path
                    == format!("/api/serviceaccounts/{GRAFANA_SERVICE_ACCOUNT_ID}/tokens")
                && request.authorization.as_deref() == Some(expected_basic_admin_auth().as_str())
        }),
        "expected token creation, got: {requests:?}"
    );
}

#[test]
fn observability_refresh_falls_back_to_monitor_config_and_repairs_runtime_copy() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let runtime_config_path = home
        .join("Library")
        .join("Application Support")
        .join("harness/observability/config.json");

    let monitor_config_path =
        write_monitor_only_shared_config(&repo, &fake_grafana.base_url, &home, &xdg_config_home);

    let token_path = xdg_config_home
        .join("harness/observability")
        .join("grafana-mcp.token");
    std::fs::create_dir_all(token_path.parent().expect("token parent")).expect("create token dir");
    std::fs::write(&token_path, STALE_TOKEN).expect("write stale token");

    let refresh_run = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--refresh-grafana-mcp-token-fixture")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .output()
        .expect("run token refresh helper");
    assert!(
        refresh_run.status.success(),
        "token refresh helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&refresh_run.stdout),
        String::from_utf8_lossy(&refresh_run.stderr)
    );

    assert_eq!(
        std::fs::read_to_string(&token_path).expect("read rotated token"),
        "fresh-token-1"
    );
    assert_eq!(fake_grafana.issued_token_count(), 1);
    assert!(
        runtime_config_path.exists(),
        "expected runtime config repair at {}",
        runtime_config_path.display()
    );
    assert_eq!(
        std::fs::read_to_string(&runtime_config_path).expect("read repaired runtime config"),
        std::fs::read_to_string(&monitor_config_path).expect("read monitor config")
    );
}

#[test]
fn observability_child_launcher_rotates_stale_grafana_token() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    super::support::write_fake_uvx_env_printer(&fake_uvx_path);

    let config_output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--write-shared-config-fixture")
        .arg("false")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .env("HARNESS_GRAFANA_URL", &fake_grafana.base_url)
        .output()
        .expect("write shared config fixture");
    assert!(
        config_output.status.success(),
        "shared config helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&config_output.stdout),
        String::from_utf8_lossy(&config_output.stderr)
    );

    let token_path = xdg_config_home
        .join("harness/observability")
        .join("grafana-mcp.token");
    std::fs::create_dir_all(token_path.parent().expect("token parent")).expect("create token dir");
    std::fs::write(&token_path, STALE_TOKEN).expect("write stale token");

    let path_env = format!(
        "{}:{}",
        fake_bin_dir.display(),
        std::env::var("PATH").expect("PATH")
    );
    let child_run = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--launch-grafana-mcp-child")
        .arg("--help")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("PATH", path_env)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .output()
        .expect("run grafana child launcher");
    assert!(
        child_run.status.success(),
        "grafana child launcher failed: stdout={} stderr={}",
        String::from_utf8_lossy(&child_run.stdout),
        String::from_utf8_lossy(&child_run.stderr)
    );

    let stdout = String::from_utf8_lossy(&child_run.stdout);
    assert!(
        stdout.contains(&format!("GRAFANA_URL={}", fake_grafana.base_url)),
        "expected child launcher to export fake grafana url, got: {stdout}"
    );
    assert!(
        stdout.contains("GRAFANA_SERVICE_ACCOUNT_TOKEN=fresh-token-1"),
        "expected child launcher to rotate the stale token, got: {stdout}"
    );
    assert!(
        stdout.contains("ARGS=mcp-grafana --help"),
        "expected child launcher to invoke uvx mcp-grafana, got: {stdout}"
    );
}

#[test]
fn observability_child_launcher_falls_back_to_monitor_config_when_runtime_copy_is_missing() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    super::support::write_fake_uvx_env_printer(&fake_uvx_path);

    write_monitor_only_shared_config(&repo, &fake_grafana.base_url, &home, &xdg_config_home);

    let token_path = xdg_config_home
        .join("harness/observability")
        .join("grafana-mcp.token");
    std::fs::create_dir_all(token_path.parent().expect("token parent")).expect("create token dir");
    std::fs::write(&token_path, STALE_TOKEN).expect("write stale token");

    let path_env = format!(
        "{}:{}",
        fake_bin_dir.display(),
        std::env::var("PATH").expect("PATH")
    );
    let child_run = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--launch-grafana-mcp-child")
        .arg("--help")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("PATH", path_env)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .output()
        .expect("run grafana child launcher");
    assert!(
        child_run.status.success(),
        "grafana child launcher failed: stdout={} stderr={}",
        String::from_utf8_lossy(&child_run.stdout),
        String::from_utf8_lossy(&child_run.stderr)
    );

    let stdout = String::from_utf8_lossy(&child_run.stdout);
    assert!(
        stdout.contains(&format!("GRAFANA_URL={}", fake_grafana.base_url)),
        "expected child launcher to export fake grafana url, got: {stdout}"
    );
    assert!(
        stdout.contains("GRAFANA_SERVICE_ACCOUNT_TOKEN=fresh-token-1"),
        "expected child launcher to rotate the stale token, got: {stdout}"
    );
}
