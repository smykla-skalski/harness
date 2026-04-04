use std::sync::OnceLock;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

use super::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionJoinRequest, SessionMutationResponse, SessionStartRequest, SignalAckRequest,
    SignalSendRequest, TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest,
    TaskUpdateRequest,
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

    fn post<Req: serde::Serialize, Res: DeserializeOwned>(
        &self,
        path: &str,
        body: &Req,
    ) -> Result<Res, CliError> {
        let url = format!("{}{path}", self.endpoint);
        let response = RUNTIME.block_on(async {
            self.http
                .post(&url)
                .bearer_auth(&self.token)
                .json(body)
                .timeout(MUTATION_TIMEOUT)
                .send()
                .await
        });

        let response = response.map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon HTTP request failed: {error}"))
        })?;

        let status = response.status();
        let body_text = RUNTIME.block_on(response.text()).map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon HTTP read body: {error}"))
        })?;

        if !status.is_success() {
            return Err(parse_error_response(&body_text, status.as_u16()));
        }

        serde_json::from_str(&body_text).map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon HTTP parse response: {error}")).into()
        })
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

    // Health check with short timeout
    let health_ok = RUNTIME.block_on(async {
        client
            .http
            .get(format!("{}/v1/health", manifest.endpoint))
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    });

    if health_ok { Some(client) } else { None }
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
