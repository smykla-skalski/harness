use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine as _;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

const GRAFANA_SERVICE_ACCOUNT_NAME: &str = "codex-grafana-mcp";
const GRAFANA_SERVICE_ACCOUNT_ID: i64 = 7;
const STALE_TOKEN: &str = "stale-token";
const GRAFANA_ADMIN_USER: &str = "observability-admin";
const GRAFANA_ADMIN_PASSWORD: &str = "observability-password";

#[derive(Clone, Debug, PartialEq, Eq)]
struct LoggedRequest {
    method: String,
    path: String,
    authorization: Option<String>,
}

#[derive(Default)]
struct FakeGrafanaState {
    requests: Vec<LoggedRequest>,
    service_account_exists: bool,
    issued_token_count: usize,
    current_valid_token: Option<String>,
}

struct FakeGrafanaServer {
    base_url: String,
    state: Arc<Mutex<FakeGrafanaState>>,
    runtime: Runtime,
    handle: JoinHandle<()>,
}

impl FakeGrafanaServer {
    fn start() -> Self {
        let runtime = Runtime::new().expect("create runtime");
        let state = Arc::new(Mutex::new(FakeGrafanaState::default()));
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
            .expect("bind fake grafana");
        let addr = listener.local_addr().expect("fake grafana addr");
        let router = Router::new()
            .route("/api/search", get(search_dashboards))
            .route("/api/serviceaccounts/search", get(search_service_accounts))
            .route("/api/serviceaccounts", post(create_service_account))
            .route(
                "/api/serviceaccounts/{id}/tokens",
                post(create_service_account_token),
            )
            .with_state(Arc::clone(&state));
        let handle = runtime.spawn(async move {
            axum::serve(listener, router)
                .await
                .expect("serve fake grafana");
        });
        Self {
            base_url: format!("http://127.0.0.1:{}", addr.port()),
            state,
            runtime,
            handle,
        }
    }

    fn requests(&self) -> Vec<LoggedRequest> {
        self.state
            .lock()
            .expect("lock fake grafana")
            .requests
            .clone()
    }

    fn issued_token_count(&self) -> usize {
        self.state
            .lock()
            .expect("lock fake grafana")
            .issued_token_count
    }
}

impl Drop for FakeGrafanaServer {
    fn drop(&mut self) {
        self.handle.abort();
        let _ = self.runtime.block_on(async { (&mut self.handle).await });
    }
}

async fn search_dashboards(
    State(state): State<Arc<Mutex<FakeGrafanaState>>>,
    headers: HeaderMap,
    Query(_query): Query<HashMap<String, String>>,
) -> (StatusCode, Json<Value>) {
    record_request(&state, "GET", "/api/search", &headers);
    let expected_authorization = state
        .lock()
        .expect("lock fake grafana")
        .current_valid_token
        .as_ref()
        .map(|token| format!("Bearer {token}"));
    match (authorization_header(&headers), expected_authorization) {
        (Some(actual), Some(expected)) if actual == expected => (
            StatusCode::OK,
            Json(json!([{ "title": "Harness System Overview" }])),
        ),
        _ => (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "message": "Unauthorized" })),
        ),
    }
}

async fn search_service_accounts(
    State(state): State<Arc<Mutex<FakeGrafanaState>>>,
    headers: HeaderMap,
    Query(_query): Query<HashMap<String, String>>,
) -> (StatusCode, Json<Value>) {
    record_request(&state, "GET", "/api/serviceaccounts/search", &headers);
    if !uses_basic_admin_auth(&headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "message": "missing basic auth" })),
        );
    }
    let service_accounts = if state
        .lock()
        .expect("lock fake grafana")
        .service_account_exists
    {
        vec![json!({
            "id": GRAFANA_SERVICE_ACCOUNT_ID,
            "name": GRAFANA_SERVICE_ACCOUNT_NAME
        })]
    } else {
        Vec::new()
    };
    (
        StatusCode::OK,
        Json(json!({
            "totalCount": service_accounts.len(),
            "serviceAccounts": service_accounts,
            "page": 1,
            "perPage": 1000
        })),
    )
}

async fn create_service_account(
    State(state): State<Arc<Mutex<FakeGrafanaState>>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    record_request(&state, "POST", "/api/serviceaccounts", &headers);
    if !uses_basic_admin_auth(&headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "message": "missing basic auth" })),
        );
    }
    state
        .lock()
        .expect("lock fake grafana")
        .service_account_exists = true;
    (
        StatusCode::OK,
        Json(json!({
            "id": GRAFANA_SERVICE_ACCOUNT_ID,
            "name": GRAFANA_SERVICE_ACCOUNT_NAME
        })),
    )
}

async fn create_service_account_token(
    State(state): State<Arc<Mutex<FakeGrafanaState>>>,
    headers: HeaderMap,
) -> (StatusCode, Json<Value>) {
    record_request(
        &state,
        "POST",
        &format!("/api/serviceaccounts/{GRAFANA_SERVICE_ACCOUNT_ID}/tokens"),
        &headers,
    );
    if !uses_basic_admin_auth(&headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "message": "missing basic auth" })),
        );
    }
    let mut guard = state.lock().expect("lock fake grafana");
    guard.service_account_exists = true;
    guard.issued_token_count += 1;
    let token = format!("fresh-token-{}", guard.issued_token_count);
    guard.current_valid_token = Some(token.clone());
    (
        StatusCode::OK,
        Json(json!({
            "id": guard.issued_token_count,
            "name": format!("token-{}", guard.issued_token_count),
            "key": token
        })),
    )
}

fn record_request(
    state: &Arc<Mutex<FakeGrafanaState>>,
    method: &str,
    path: &str,
    headers: &HeaderMap,
) {
    state
        .lock()
        .expect("lock fake grafana")
        .requests
        .push(LoggedRequest {
            method: method.to_string(),
            path: path.to_string(),
            authorization: authorization_header(headers),
        });
}

fn authorization_header(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(ToString::to_string)
}

fn uses_basic_admin_auth(headers: &HeaderMap) -> bool {
    authorization_header(headers).as_deref() == Some(expected_basic_admin_auth().as_str())
}

fn expected_basic_admin_auth() -> String {
    let credentials = format!("{GRAFANA_ADMIN_USER}:{GRAFANA_ADMIN_PASSWORD}");
    let encoded = base64::engine::general_purpose::STANDARD.encode(credentials);
    format!("Basic {encoded}")
}

fn parse_output_lines(output: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(output)
        .lines()
        .map(ToString::to_string)
        .collect()
}

fn write_fake_uvx_env_printer(path: &PathBuf) {
    std::fs::create_dir_all(path.parent().expect("fake uvx parent")).expect("create fake uvx dir");
    std::fs::write(
        path,
        "#!/bin/sh\nprintf 'GRAFANA_URL=%s\\n' \"${GRAFANA_URL:-}\"\nprintf 'GRAFANA_SERVICE_ACCOUNT_TOKEN=%s\\n' \"${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}\"\nprintf 'ARGS=%s\\n' \"$*\"\n",
    )
    .expect("write fake uvx");
    #[allow(clippy::permissions_set_readonly_false)]
    std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod fake uvx");
}

fn write_fake_uvx_mcp_server(path: &PathBuf) {
    std::fs::create_dir_all(path.parent().expect("fake uvx parent")).expect("create fake uvx dir");
    std::fs::write(
        path,
        r#"#!/usr/bin/env python3
import json
import os
import pathlib
import sys

log_path = os.environ.get("FAKE_UVX_START_LOG")
if log_path:
    pathlib.Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(os.environ.get("GRAFANA_SERVICE_ACCOUNT_TOKEN", "") + "\n")

def read_message():
    line = sys.stdin.buffer.readline()
    if line == b"":
        return None
    return json.loads(line.decode("utf-8"))

def write_message(payload):
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    sys.stdout.buffer.write(body + b"\n")
    sys.stdout.buffer.flush()

token = os.environ.get("GRAFANA_SERVICE_ACCOUNT_TOKEN", "")

while True:
    message = read_message()
    if message is None:
        break
    method = message.get("method")
    if method == "initialize":
        write_message(
            {
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "serverInfo": {"name": "fake-grafana", "version": token},
                },
            }
        )
    elif method == "tools/list":
        write_message(
            {
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": {"tools": [{"name": token}]},
            }
        )
"#,
    )
    .expect("write fake uvx mcp server");
    #[allow(clippy::permissions_set_readonly_false)]
    std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .expect("chmod fake uvx mcp server");
}

fn write_mcp_message(stdin: &mut ChildStdin, payload: &Value) {
    let body = serde_json::to_vec(payload).expect("serialize mcp payload");
    write!(stdin, "Content-Length: {}\r\n\r\n", body.len()).expect("write mcp header");
    stdin.write_all(&body).expect("write mcp body");
    stdin.flush().expect("flush mcp body");
}

fn read_mcp_message(stdout: &mut BufReader<ChildStdout>) -> Option<Value> {
    let mut content_length = None;
    loop {
        let mut line = String::new();
        let bytes = stdout.read_line(&mut line).expect("read mcp header line");
        if bytes == 0 {
            return None;
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        if let Some(value) = line.trim().strip_prefix("Content-Length:") {
            content_length = Some(value.trim().parse::<usize>().expect("parse content length"));
        }
    }
    let content_length = content_length.expect("missing Content-Length header");
    let mut body = vec![0; content_length];
    stdout.read_exact(&mut body).expect("read mcp body");
    Some(serde_json::from_slice(&body).expect("decode mcp body"))
}

fn spawn_mcp_response_reader(stdout: ChildStdout) -> Receiver<Value> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut stdout = BufReader::new(stdout);
        loop {
            let Some(message) = read_mcp_message(&mut stdout) else {
                return;
            };
            if sender.send(message).is_err() {
                return;
            }
        }
    });
    receiver
}

fn write_json_line_message(stdin: &mut ChildStdin, payload: &Value) {
    let body = serde_json::to_vec(payload).expect("serialize json line payload");
    stdin.write_all(&body).expect("write json line body");
    stdin.write_all(b"\n").expect("write json line newline");
    stdin.flush().expect("flush json line payload");
}

fn spawn_json_line_response_reader(stdout: ChildStdout) -> Receiver<Value> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let stdout = BufReader::new(stdout);
        for line in stdout.lines() {
            let line = line.expect("read json line");
            if line.trim().is_empty() {
                continue;
            }
            let payload = serde_json::from_str::<Value>(&line).expect("decode json line");
            if sender.send(payload).is_err() {
                return;
            }
        }
    });
    receiver
}

fn wait_for<F>(description: &str, predicate: F)
where
    F: Fn() -> bool,
{
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("timed out waiting for {description}");
}

fn read_log_tokens(path: &PathBuf) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(ToString::to_string)
        .collect()
}

fn spawn_launcher(
    launcher_path: &PathBuf,
    repo: &PathBuf,
    home: &PathBuf,
    xdg_config_home: &PathBuf,
    xdg_data_home: &PathBuf,
    fake_bin_dir: &PathBuf,
    start_log_path: &PathBuf,
) -> Child {
    let path_env = format!(
        "{}:{}",
        fake_bin_dir.display(),
        std::env::var("PATH").expect("PATH")
    );
    Command::new(launcher_path)
        .current_dir(repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", home)
        .env("PATH", path_env)
        .env("XDG_CONFIG_HOME", xdg_config_home)
        .env("XDG_DATA_HOME", xdg_data_home)
        .env("FAKE_UVX_START_LOG", start_log_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn grafana launcher")
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
fn observability_child_launcher_rotates_stale_grafana_token() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    write_fake_uvx_env_printer(&fake_uvx_path);

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
    assert_eq!(tools_response["result"]["tools"][0]["name"], "fresh-token-1");

    drop(stdin);
    let status = launcher.wait().expect("wait for launcher exit");
    assert!(
        status.success(),
        "launcher did not exit cleanly: {status:?}"
    );
}
