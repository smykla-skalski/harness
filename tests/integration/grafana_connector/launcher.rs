use std::env;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use serde_json::json;
use tempfile::tempdir;

use super::support::{
    FakeGrafanaServer, GRAFANA_ADMIN_PASSWORD, GRAFANA_ADMIN_USER, STALE_TOKEN, parse_output_lines,
    read_log_tokens, spawn_json_line_response_reader, spawn_launcher, spawn_mcp_response_reader,
    wait_for, write_fake_uvx_mcp_server, write_json_line_message, write_mcp_message,
};

#[test]
fn observability_launcher_restarts_child_after_token_refresh() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    let start_log_path = tmp.path().join("fake-uvx-starts.log");
    write_fake_uvx_mcp_server(&fake_uvx_path);

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

    let launcher_output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--install-grafana-mcp-launcher-fixture")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .output()
        .expect("install grafana launcher fixture");
    assert!(
        launcher_output.status.success(),
        "launcher helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&launcher_output.stdout),
        String::from_utf8_lossy(&launcher_output.stderr)
    );

    let launcher_path = PathBuf::from(
        parse_output_lines(&launcher_output.stdout)
            .into_iter()
            .next()
            .expect("launcher path output"),
    );
    let token_path = xdg_config_home
        .join("harness/observability")
        .join("grafana-mcp.token");
    std::fs::create_dir_all(token_path.parent().expect("token parent")).expect("create token dir");
    std::fs::write(&token_path, STALE_TOKEN).expect("write stale token");

    let mut launcher = spawn_launcher(
        &launcher_path,
        &repo,
        &home,
        &xdg_config_home,
        &xdg_data_home,
        &fake_bin_dir,
        &start_log_path,
    );
    let mut stdin = launcher.stdin.take().expect("launcher stdin");
    let stdout = launcher.stdout.take().expect("launcher stdout");
    let responses = spawn_mcp_response_reader(stdout);

    write_mcp_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "grafana-test", "version": "1.0"}
            }
        }),
    );
    let initialize_response = responses
        .recv_timeout(Duration::from_secs(3))
        .expect("expected initialize response from launcher");
    assert_eq!(initialize_response["id"], 1);
    assert_eq!(
        initialize_response["result"]["serverInfo"]["version"],
        "fresh-token-1"
    );

    write_mcp_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {}
        }),
    );
    write_mcp_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }),
    );
    let first_tools_response = responses
        .recv_timeout(Duration::from_secs(3))
        .expect("expected first tools/list response from launcher");
    assert_eq!(first_tools_response["id"], 2);
    assert_eq!(
        first_tools_response["result"]["tools"][0]["name"],
        "fresh-token-1"
    );

    std::fs::write(&token_path, STALE_TOKEN).expect("overwrite token with stale value");
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

    wait_for("second token issuance", || {
        fake_grafana.issued_token_count() == 2
    });
    wait_for("launcher restart with refreshed token", || {
        let tokens = read_log_tokens(&start_log_path);
        tokens.len() >= 2 && tokens.last().is_some_and(|token| token == "fresh-token-2")
    });

    write_mcp_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": {}
        }),
    );
    let second_tools_response = responses
        .recv_timeout(Duration::from_secs(3))
        .expect("expected second tools/list response from launcher");
    assert_eq!(second_tools_response["id"], 3);
    assert_eq!(
        second_tools_response["result"]["tools"][0]["name"],
        "fresh-token-2"
    );

    drop(stdin);
    let status = launcher.wait().expect("wait for launcher exit");
    assert!(
        status.success(),
        "launcher did not exit cleanly: {status:?}"
    );
}

#[test]
fn observability_launcher_accepts_line_delimited_client_transport() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    let start_log_path = tmp.path().join("fake-uvx-starts.log");
    write_fake_uvx_mcp_server(&fake_uvx_path);

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

    let launcher_output = Command::new("/bin/bash")
        .arg(repo.join("scripts/observability.sh"))
        .arg("--install-grafana-mcp-launcher-fixture")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .output()
        .expect("install grafana launcher fixture");
    assert!(
        launcher_output.status.success(),
        "launcher helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&launcher_output.stdout),
        String::from_utf8_lossy(&launcher_output.stderr)
    );

    let launcher_path = PathBuf::from(
        parse_output_lines(&launcher_output.stdout)
            .into_iter()
            .next()
            .expect("launcher path output"),
    );

    let mut launcher = spawn_launcher(
        &launcher_path,
        &repo,
        &home,
        &xdg_config_home,
        &xdg_data_home,
        &fake_bin_dir,
        &start_log_path,
    );
    let mut stdin = launcher.stdin.take().expect("launcher stdin");
    let stdout = launcher.stdout.take().expect("launcher stdout");
    let responses = spawn_json_line_response_reader(stdout);

    write_json_line_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "codex-test", "version": "1.0"}
            }
        }),
    );
    let initialize_response = responses
        .recv_timeout(Duration::from_secs(3))
        .expect("expected initialize response from launcher");
    assert_eq!(initialize_response["id"], 1);
    assert_eq!(
        initialize_response["result"]["serverInfo"]["version"],
        "fresh-token-1"
    );

    write_json_line_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {}
        }),
    );
    write_json_line_message(
        &mut stdin,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }),
    );
    let tools_response = responses
        .recv_timeout(Duration::from_secs(3))
        .expect("expected tools/list response from launcher");
    assert_eq!(tools_response["id"], 2);
    assert_eq!(
        tools_response["result"]["tools"][0]["name"],
        "fresh-token-1"
    );

    drop(stdin);
    let status = launcher.wait().expect("wait for launcher exit");
    assert!(
        status.success(),
        "launcher did not exit cleanly: {status:?}"
    );
}
