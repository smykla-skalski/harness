use std::thread;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde_json::Value;
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;
use crate::infra::io::read_json_typed;

use super::agent_tui::{
    AgentTuiInputRequest, AgentTuiListResponse, AgentTuiResizeRequest, AgentTuiSnapshot,
    AgentTuiStartRequest,
};
use super::discovery;
use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionJoinRequest, SessionMutationResponse, SessionStartRequest, SessionSummary,
    SignalAckRequest, SignalCancelRequest, SignalSendRequest, TaskAssignRequest,
    TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest, TaskUpdateRequest,
};
use super::state;
use crate::session::types::SessionState;

const HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const API_READY_TIMEOUT: Duration = Duration::from_secs(2);
const API_READY_INTERVAL: Duration = Duration::from_millis(100);
const MUTATION_TIMEOUT: Duration = Duration::from_secs(5);

/// HTTP client for daemon-first session mutations.
///
/// Reads the daemon manifest and auth token, then proxies session
/// operations through the daemon's HTTP API instead of writing files.
pub struct DaemonClient {
    endpoint: String,
    token: String,
    http: reqwest::Client,
}

#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    /// Attempt to connect to a running daemon.
    ///
    /// Returns `None` if the daemon is not running or unreachable.
    ///
    /// This is intentionally uncached. Discovery can legitimately resolve to a
    /// different daemon root after env changes, daemon adoption, or a restart,
    /// and pinning the first successful client can route later operations into
    /// the wrong daemon.
    #[must_use]
    pub fn try_connect() -> Option<Self> {
        try_build_client()
    }

    pub fn start_session(&self, request: &SessionStartRequest) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse = self.post("/v1/sessions", request)?;
        Ok(response.state)
    }

    pub fn join_session(
        &self,
        session_id: &str,
        request: &SessionJoinRequest,
    ) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse =
            self.post(&format!("/v1/sessions/{session_id}/join"), request)?;
        Ok(response.state)
    }

    pub fn end_session(
        &self,
        session_id: &str,
        request: &SessionEndRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/end"), request)
    }

    pub fn assign_role(
        &self,
        session_id: &str,
        agent_id: &str,
        request: &RoleChangeRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/agents/{agent_id}/role"),
            request,
        )
    }

    pub fn remove_agent(
        &self,
        session_id: &str,
        agent_id: &str,
        request: &AgentRemoveRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/agents/{agent_id}/remove"),
            request,
        )
    }

    pub fn transfer_leader(
        &self,
        session_id: &str,
        request: &LeaderTransferRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/leader"), request)
    }

    pub fn create_task(
        &self,
        session_id: &str,
        request: &TaskCreateRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/task"), request)
    }

    pub fn assign_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskAssignRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/assign"),
            request,
        )
    }

    pub fn drop_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskDropRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/drop"),
            request,
        )
    }

    pub fn update_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskUpdateRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/status"),
            request,
        )
    }

    pub fn checkpoint_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskCheckpointRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/checkpoint"),
            request,
        )
    }

    pub fn send_signal(
        &self,
        session_id: &str,
        request: &SignalSendRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/signal"), request)
    }

    pub fn record_signal_ack(
        &self,
        session_id: &str,
        request: &SignalAckRequest,
    ) -> Result<(), CliError> {
        let _: Value = self.post(&format!("/v1/sessions/{session_id}/signal-ack"), request)?;
        Ok(())
    }

    pub fn cancel_signal(
        &self,
        session_id: &str,
        request: &SignalCancelRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/signal-cancel"), request)
    }

    pub fn start_agent_tui(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/agent-tuis"), request)
    }

    pub fn send_agent_tui_input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/agent-tuis/{tui_id}/input"), request)
    }

    pub fn resize_agent_tui(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/agent-tuis/{tui_id}/resize"), request)
    }

    pub fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let body = serde_json::json!({});
        self.post(&format!("/v1/agent-tuis/{tui_id}/stop"), &body)
    }

    // --- Read operations ---

    pub fn get_session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        self.get(&format!("/v1/sessions/{session_id}"))
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionSummary>, CliError> {
        self.get("/v1/sessions")
    }

    pub fn list_agent_tuis(&self, session_id: &str) -> Result<AgentTuiListResponse, CliError> {
        self.get(&format!("/v1/sessions/{session_id}/agent-tuis"))
    }

    pub fn get_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.get(&format!("/v1/agent-tuis/{tui_id}"))
    }

    // --- HTTP helpers ---

    fn get<Res: DeserializeOwned>(&self, path: &str) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let response = RUNTIME.block_on(async {
            self.http
                .get(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .timeout(MUTATION_TIMEOUT)
                .send()
                .await
        });
        process_response(response, "GET", path, &request_id, &start)
    }

    fn post<Req: serde::Serialize, Res: DeserializeOwned>(
        &self,
        path: &str,
        body: &Req,
    ) -> Result<Res, CliError> {
        let request_id = Uuid::new_v4().to_string();
        let start = Instant::now();
        let url = format!("{}{path}", self.endpoint);
        let response = RUNTIME.block_on(async {
            self.http
                .post(&url)
                .bearer_auth(&self.token)
                .header("x-request-id", &request_id)
                .json(body)
                .timeout(MUTATION_TIMEOUT)
                .send()
                .await
        });
        process_response(response, "POST", path, &request_id, &start)
    }
}

fn try_build_client() -> Option<DaemonClient> {
    let root = discovery::running_daemon_location()?.root;
    let manifest: state::DaemonManifest = read_json_typed(&root.join("manifest.json")).ok()?;
    let token = fs_err::read_to_string(root.join("auth-token"))
        .ok()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())?;

    let http = reqwest::Client::builder().build().ok()?;

    let client = DaemonClient {
        endpoint: manifest.endpoint.clone(),
        token,
        http,
    };

    if check_daemon_health(&client, &manifest.endpoint)
        && wait_for_authenticated_api(&client, API_READY_TIMEOUT)
    {
        Some(client)
    } else {
        None
    }
}

fn check_daemon_health(client: &DaemonClient, endpoint: &str) -> bool {
    let start = Instant::now();
    let health_ok = RUNTIME.block_on(async {
        client
            .http
            .get(format!("{endpoint}/v1/health"))
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    });
    let health_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    log_health_result(endpoint, health_ms, health_ok);
    health_ok
}

fn log_health_result(endpoint: &str, health_ms: u64, ok: bool) {
    if ok {
        log_health_connected(endpoint, health_ms);
    } else {
        log_health_failed(endpoint, health_ms);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "deadline-based warmup loop keeps daemon connection readiness explicit"
)]
fn wait_for_authenticated_api(client: &DaemonClient, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if authenticated_api_ready(client) {
            return true;
        }
        if Instant::now() >= deadline {
            tracing::debug!(endpoint = client.endpoint, "daemon session API not ready");
            return false;
        }
        thread::sleep(API_READY_INTERVAL);
    }
}

fn authenticated_api_ready(client: &DaemonClient) -> bool {
    let url = format!("{}/v1/sessions", client.endpoint);
    RUNTIME.block_on(async {
        client
            .http
            .get(&url)
            .bearer_auth(&client.token)
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_health_connected(endpoint: &str, health_ms: u64) {
    tracing::info!(endpoint, health_ms, "daemon client connected");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_health_failed(endpoint: &str, health_ms: u64) {
    tracing::debug!(endpoint, health_ms, "daemon health check failed");
}

fn process_response<Res: DeserializeOwned>(
    response: Result<reqwest::Response, reqwest::Error>,
    method: &str,
    path: &str,
    request_id: &str,
    start: &Instant,
) -> Result<Res, CliError> {
    let response = response.map_err(|error| {
        log_client_request(method, path, 0, start, request_id, true);
        CliErrorKind::workflow_io(format!("daemon HTTP request failed: {error}"))
    })?;

    let status = response.status().as_u16();
    let body_text = RUNTIME
        .block_on(response.text())
        .map_err(|error| CliErrorKind::workflow_io(format!("daemon HTTP read body: {error}")))?;

    let failed = !(200..300).contains(&status);
    log_client_request(method, path, status, start, request_id, failed);

    if failed {
        return Err(parse_error_response(&body_text, status));
    }

    serde_json::from_str(&body_text).map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon HTTP parse response: {error}")).into()
    })
}

fn log_client_request(
    method: &str,
    path: &str,
    status: u16,
    start: &Instant,
    request_id: &str,
    is_error: bool,
) {
    let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    if is_error {
        log_client_warn(method, path, status, duration_ms, request_id);
    } else {
        log_client_debug(method, path, status, duration_ms, request_id);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_client_warn(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::warn!(
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon client request failed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_client_debug(method: &str, path: &str, status: u16, duration_ms: u64, request_id: &str) {
    tracing::debug!(
        method,
        path,
        status,
        duration_ms,
        request_id,
        "daemon client request"
    );
}

fn parse_error_response(body: &str, status: u16) -> CliError {
    if let Ok(parsed) = serde_json::from_str::<Value>(body)
        && let Some(error) = parsed.get("error")
    {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("daemon returned an error");
        let code = error
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("DAEMON_ERROR");
        return CliErrorKind::workflow_io(format!(
            "daemon error ({code}, HTTP {status}): {message}"
        ))
        .into();
    }
    CliErrorKind::workflow_io(format!("daemon HTTP {status}: {body}")).into()
}

#[cfg(test)]
mod tests {
    use std::fs::OpenOptions;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread;

    use fs2::FileExt;

    use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
    use crate::daemon::transport::HARNESS_MONITOR_APP_GROUP_ID;

    use super::*;

    #[test]
    fn try_connect_returns_none_when_no_daemon() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).expect("create home");
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8"))),
                ("HOME", Some(home.to_str().expect("utf8 home"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
            ],
            || {
                let client = try_build_client();
                assert!(client.is_none());
            },
        );
    }

    #[test]
    fn parse_error_response_extracts_message() {
        let body = r#"{"error":{"code":"KSRCLI092","message":"agent conflict"}}"#;
        let error = parse_error_response(body, 400);
        assert!(error.to_string().contains("agent conflict"));
    }

    #[test]
    fn parse_error_response_handles_plain_text() {
        let error = parse_error_response("not json", 500);
        assert!(error.to_string().contains("500"));
    }

    #[test]
    fn wait_for_authenticated_api_retries_until_sessions_endpoint_succeeds() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let saw_auth = Arc::new(AtomicBool::new(false));
        let session_calls = Arc::new(AtomicUsize::new(0));

        let server = {
            let saw_auth = Arc::clone(&saw_auth);
            let session_calls = Arc::clone(&session_calls);
            thread::spawn(move || {
                for _ in 0..2 {
                    let (mut stream, _) = listener.accept().expect("accept");
                    let request = read_http_request(&mut stream);
                    if request
                        .to_ascii_lowercase()
                        .contains("authorization: bearer test-token")
                    {
                        saw_auth.store(true, Ordering::SeqCst);
                    }
                    let call_index = session_calls.fetch_add(1, Ordering::SeqCst);
                    if call_index == 0 {
                        write_http_response(
                            &mut stream,
                            "503 Service Unavailable",
                            "application/json",
                            "{\"error\":\"warming up\"}",
                        );
                    } else {
                        write_http_response(&mut stream, "200 OK", "application/json", "[]");
                    }
                }
            })
        };

        let client = DaemonClient {
            endpoint,
            token: "test-token".to_string(),
            http: reqwest::Client::new(),
        };
        assert!(wait_for_authenticated_api(
            &client,
            Duration::from_millis(250)
        ));
        assert!(saw_auth.load(Ordering::SeqCst));
        assert_eq!(session_calls.load(Ordering::SeqCst), 2);
        server.join().expect("server");
    }

    #[test]
    fn wait_for_authenticated_api_returns_false_when_sessions_endpoint_never_recovers() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let session_calls = Arc::new(AtomicUsize::new(0));

        let server = {
            let session_calls = Arc::clone(&session_calls);
            thread::spawn(move || {
                for _ in 0..3 {
                    let (mut stream, _) = listener.accept().expect("accept");
                    let _request = read_http_request(&mut stream);
                    session_calls.fetch_add(1, Ordering::SeqCst);
                    write_http_response(
                        &mut stream,
                        "503 Service Unavailable",
                        "application/json",
                        "{\"error\":\"still warming up\"}",
                    );
                }
            })
        };

        let client = DaemonClient {
            endpoint,
            token: "test-token".to_string(),
            http: reqwest::Client::new(),
        };
        assert!(!wait_for_authenticated_api(
            &client,
            Duration::from_millis(250)
        ));
        assert!(session_calls.load(Ordering::SeqCst) >= 2);
        server.join().expect("server");
    }

    #[test]
    fn try_build_client_requires_authenticated_api_readiness() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        let xdg = tmp.path().join("xdg");
        std::fs::create_dir_all(&home).expect("create home");
        let xdg_str = xdg.to_str().expect("utf8 xdg").to_string();
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));

        let server = thread::spawn(move || {
            for request_index in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                if request.starts_with("GET /v1/health ") {
                    write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                    continue;
                }
                assert!(request.starts_with("GET /v1/sessions "));
                let request_lower = request.to_ascii_lowercase();
                assert!(
                    request_lower.contains("authorization: bearer test-token"),
                    "missing bearer auth: {request}"
                );
                let body = if request_index == 1 {
                    "{\"error\":\"warming up\"}"
                } else {
                    "[]"
                };
                let status = if request_index == 1 {
                    "503 Service Unavailable"
                } else {
                    "200 OK"
                };
                write_http_response(&mut stream, status, "application/json", body);
            }
        });

        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_str.as_str())),
                ("HOME", Some(home.to_str().expect("utf8 home"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
            ],
            || {
                std::fs::create_dir_all(&xdg).expect("create xdg");
                let daemon_root = state::daemon_root();
                std::fs::create_dir_all(&daemon_root).expect("create daemon root");
                let lock_path = daemon_root.join(state::DAEMON_LOCK_FILE);
                let lock_file = OpenOptions::new()
                    .create(true)
                    .read(true)
                    .write(true)
                    .truncate(false)
                    .open(&lock_path)
                    .expect("open daemon lock");
                lock_file
                    .try_lock_exclusive()
                    .expect("hold daemon singleton lock");
                let token_path = state::auth_token_path();
                std::fs::create_dir_all(token_path.parent().expect("token parent"))
                    .expect("create daemon dir");
                std::fs::write(&token_path, "test-token").expect("write token");

                let manifest = DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").to_string(),
                    pid: std::process::id(),
                    endpoint: endpoint.clone(),
                    started_at: "2026-04-11T00:00:00Z".to_string(),
                    token_path: token_path.display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                state::write_manifest(&manifest).expect("write manifest");

                let client = try_build_client();
                assert!(client.is_some(), "authenticated session API should warm up");
            },
        );

        server.join().expect("server");
    }

    #[test]
    fn try_build_client_discovers_running_app_group_daemon_when_default_root_is_empty() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        let xdg = tmp.path().join("xdg");
        std::fs::create_dir_all(&home).expect("create home");
        std::fs::create_dir_all(&xdg).expect("create xdg");

        let app_group_root = home
            .join("Library")
            .join("Group Containers")
            .join(HARNESS_MONITOR_APP_GROUP_ID)
            .join("harness")
            .join("daemon");
        std::fs::create_dir_all(&app_group_root).expect("create app group daemon root");

        let lock_path = app_group_root.join(state::DAEMON_LOCK_FILE);
        let lock_file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .expect("open daemon lock");
        lock_file
            .try_lock_exclusive()
            .expect("hold daemon singleton lock");

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let server = thread::spawn(move || {
            for request_index in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                if request.starts_with("GET /v1/health ") {
                    write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                    continue;
                }
                assert!(request.starts_with("GET /v1/sessions "));
                let request_lower = request.to_ascii_lowercase();
                assert!(
                    request_lower.contains("authorization: bearer test-token"),
                    "missing bearer auth: {request}"
                );
                let status = if request_index == 1 {
                    "503 Service Unavailable"
                } else {
                    "200 OK"
                };
                let body = if request_index == 1 {
                    "{\"error\":\"warming up\"}"
                } else {
                    "[]"
                };
                write_http_response(&mut stream, status, "application/json", body);
            }
        });

        temp_env::with_vars(
            [
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
                ("HOME", Some(home.to_str().expect("utf8 home"))),
                ("XDG_DATA_HOME", Some(xdg.to_str().expect("utf8 xdg"))),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
            ],
            || {
                std::fs::write(app_group_root.join("auth-token"), "test-token")
                    .expect("write token");
                let manifest = DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").to_string(),
                    pid: std::process::id(),
                    endpoint: endpoint.clone(),
                    started_at: "2026-04-11T00:00:00Z".to_string(),
                    token_path: app_group_root.join("auth-token").display().to_string(),
                    sandboxed: true,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                std::fs::write(
                    app_group_root.join("manifest.json"),
                    serde_json::to_string_pretty(&manifest).expect("serialize manifest"),
                )
                .expect("write manifest");

                let client = try_build_client().expect("discover running app group daemon");
                assert_eq!(client.endpoint, endpoint);
                assert_eq!(client.token, "test-token");
                assert_eq!(
                    state::daemon_root(),
                    xdg.join("harness").join("daemon"),
                    "daemon client discovery must not mutate the process root"
                );
            },
        );

        server.join().expect("server");
    }

    #[test]
    fn try_connect_rebuilds_after_environment_changes() {
        let first = tempfile::tempdir().expect("first tempdir");
        let second = tempfile::tempdir().expect("second tempdir");

        let (first_endpoint, first_lock, first_server) =
            fake_running_xdg_daemon(first.path(), "first-token");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(first.path().to_str().expect("utf8 xdg")),
                ),
                (
                    "HOME",
                    Some(first.path().join("home").to_str().expect("utf8 home")),
                ),
                (
                    "HARNESS_HOST_HOME",
                    Some(first.path().join("home").to_str().expect("utf8 home")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
            ],
            || {
                let client = DaemonClient::try_connect().expect("first daemon client");
                assert_eq!(client.endpoint, first_endpoint);
                assert_eq!(client.token, "first-token");
            },
        );
        drop(first_lock);
        first_server.join().expect("first server");

        let (second_endpoint, second_lock, second_server) =
            fake_running_xdg_daemon(second.path(), "second-token");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(second.path().to_str().expect("utf8 xdg")),
                ),
                (
                    "HOME",
                    Some(second.path().join("home").to_str().expect("utf8 home")),
                ),
                (
                    "HARNESS_HOST_HOME",
                    Some(second.path().join("home").to_str().expect("utf8 home")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
            ],
            || {
                let client = DaemonClient::try_connect().expect("second daemon client");
                assert_eq!(client.endpoint, second_endpoint);
                assert_eq!(client.token, "second-token");
            },
        );
        drop(second_lock);
        second_server.join().expect("second server");
    }

    fn fake_running_xdg_daemon(
        xdg_root: &std::path::Path,
        token: &str,
    ) -> (String, std::fs::File, thread::JoinHandle<()>) {
        let home = xdg_root.join("home");
        std::fs::create_dir_all(&home).expect("create home");
        std::fs::create_dir_all(xdg_root).expect("create xdg");

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token_value = token.to_string();
        let server = thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                if request.starts_with("GET /v1/health ") {
                    write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                    continue;
                }
                assert!(request.starts_with("GET /v1/sessions "));
                let request_lower = request.to_ascii_lowercase();
                assert!(
                    request_lower.contains(&format!(
                        "authorization: bearer {}",
                        token_value.to_ascii_lowercase()
                    )),
                    "missing bearer auth: {request}"
                );
                write_http_response(&mut stream, "200 OK", "application/json", "[]");
            }
        });

        let daemon_root = xdg_root.join("harness").join("daemon");
        std::fs::create_dir_all(&daemon_root).expect("create daemon root");
        let lock_file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(daemon_root.join(state::DAEMON_LOCK_FILE))
            .expect("open daemon lock");
        lock_file
            .try_lock_exclusive()
            .expect("hold daemon singleton lock");
        let token_path = daemon_root.join("auth-token");
        std::fs::write(&token_path, token).expect("write token");
        std::fs::write(
            daemon_root.join("manifest.json"),
            serde_json::to_string_pretty(&DaemonManifest {
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: std::process::id(),
                endpoint: endpoint.clone(),
                started_at: "2026-04-11T00:00:00Z".to_string(),
                token_path: token_path.display().to_string(),
                sandboxed: false,
                host_bridge: HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
            })
            .expect("serialize manifest"),
        )
        .expect("write manifest");

        (endpoint, lock_file, server)
    }

    fn read_http_request(stream: &mut std::net::TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        let mut buffer = Vec::new();
        loop {
            let mut chunk = [0_u8; 1024];
            let read = stream.read(&mut chunk).expect("read request");
            if read == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..read]);
            if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8(buffer).expect("utf8 request")
    }

    fn write_http_response(
        stream: &mut std::net::TcpStream,
        status: &str,
        content_type: &str,
        body: &str,
    ) {
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream
            .write_all(response.as_bytes())
            .expect("write response");
        stream.flush().expect("flush response");
    }
}
