use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};

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
const FRESH_TOKEN: &str = "fresh-token";
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
    match authorization_header(&headers).as_deref() {
        Some(value) if value == format!("Bearer {FRESH_TOKEN}") => (
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
    (
        StatusCode::OK,
        Json(json!({
            "id": guard.issued_token_count,
            "name": format!("token-{}", guard.issued_token_count),
            "key": FRESH_TOKEN
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

fn write_fake_uvx(path: &PathBuf) {
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

#[test]
fn observability_launcher_refreshes_stale_grafana_token_after_stack_recreation() {
    let tmp = tempdir().expect("tempdir");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fake_grafana = FakeGrafanaServer::start();

    let home = tmp.path().join("home");
    let xdg_config_home = tmp.path().join("xdg-config");
    let xdg_data_home = tmp.path().join("xdg-data");
    let fake_bin_dir = tmp.path().join("fake-bin");
    let fake_uvx_path = fake_bin_dir.join("uvx");
    write_fake_uvx(&fake_uvx_path);

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

    let path_env = format!(
        "{}:{}",
        fake_bin_dir.display(),
        std::env::var("PATH").expect("PATH")
    );
    let launcher_run = Command::new(&launcher_path)
        .arg("--help")
        .current_dir(&repo)
        .env("GF_SECURITY_ADMIN_USER", GRAFANA_ADMIN_USER)
        .env("GF_SECURITY_ADMIN_PASSWORD", GRAFANA_ADMIN_PASSWORD)
        .env("HOME", &home)
        .env("PATH", path_env)
        .env("XDG_CONFIG_HOME", &xdg_config_home)
        .env("XDG_DATA_HOME", &xdg_data_home)
        .output()
        .expect("run launcher");
    assert!(
        launcher_run.status.success(),
        "launcher failed: stdout={} stderr={}",
        String::from_utf8_lossy(&launcher_run.stdout),
        String::from_utf8_lossy(&launcher_run.stderr)
    );

    let stdout = String::from_utf8_lossy(&launcher_run.stdout);
    assert!(
        stdout.contains(&format!("GRAFANA_URL={}", fake_grafana.base_url)),
        "expected launcher to export fake grafana url, got: {stdout}"
    );
    assert!(
        stdout.contains(&format!("GRAFANA_SERVICE_ACCOUNT_TOKEN={FRESH_TOKEN}")),
        "expected launcher to rotate the stale token, got: {stdout}"
    );
    assert!(
        stdout.contains("ARGS=mcp-grafana --help"),
        "expected launcher to invoke uvx mcp-grafana, got: {stdout}"
    );
    assert_eq!(
        std::fs::read_to_string(&token_path).expect("read rotated token"),
        FRESH_TOKEN
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
