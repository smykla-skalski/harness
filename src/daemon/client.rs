use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde_json::Value;
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionJoinRequest, SessionMutationResponse, SessionStartRequest, SessionSummary,
    SignalAckRequest, SignalCancelRequest, SignalSendRequest, TaskAssignRequest,
    TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest, TaskUpdateRequest,
};
use super::state;
use crate::session::types::SessionState;

const HEALTH_TIMEOUT: Duration = Duration::from_millis(500);
const MUTATION_TIMEOUT: Duration = Duration::from_secs(5);

static CACHED_CLIENT: OnceLock<Option<DaemonClient>> = OnceLock::new();

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
    /// The result is cached for the lifetime of the process.
    #[must_use]
    pub fn try_connect() -> Option<&'static Self> {
        CACHED_CLIENT.get_or_init(try_build_client).as_ref()
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

    // --- Read operations ---

    pub fn get_session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        self.get(&format!("/v1/sessions/{session_id}"))
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionSummary>, CliError> {
        self.get("/v1/sessions")
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
    let manifest = state::load_manifest().ok()??;
    let token = fs_err::read_to_string(state::auth_token_path())
        .ok()
        .map(|token| token.trim().to_string())?;

    let http = reqwest::Client::builder().build().ok()?;

    let client = DaemonClient {
        endpoint: manifest.endpoint.clone(),
        token,
        http,
    };

    if check_daemon_health(&client, &manifest.endpoint) {
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
    use super::*;

    #[test]
    fn try_connect_returns_none_when_no_daemon() {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8")))],
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
}
