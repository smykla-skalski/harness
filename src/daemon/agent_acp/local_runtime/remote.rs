//! Connecting to a remote ACP agent over HTTP or WebSocket.
//!
//! The daemon never spawns these agents, so there is no child to reap, no
//! stderr to tail, and no process pool to key on. The session otherwise runs
//! the same protocol loop as a local agent, behind a childless supervisor.

use std::sync::Arc;

use agent_client_protocol_http::HttpClient;
use harness_protocol::managed_agents::acp::AcpEndpoint;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};

use crate::agents::acp::permission::recording_log_path_for_session;
use crate::agents::acp::supervision::{AcpSessionSupervisor, SupervisedProcess, SupervisionConfig};
use crate::errors::{CliError, CliErrorKind};

use super::super::active::{ActiveAcpProcess, ActiveAcpTasks, SharedStderrTail, spawn_event_forwarder};
use super::super::manager::{AcpAgentManagerHandle, AcpAgentSnapshot};
use super::super::permission_bridge::PermissionBridgeHandle;
use super::super::prompt_gate::PromptGate;
use super::super::protocol::AcpTransport;
use super::rollback::rollback_registration_best_effort;
use super::snapshots::{StartedSnapshotInput, started_snapshot};
use super::{DescriptorStartInput, StartedProcessContext};

impl AcpAgentManagerHandle {
    pub(super) fn start_remote_connect_session(
        &self,
        input: DescriptorStartInput<'_>,
        endpoint: &AcpEndpoint,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let client = build_http_client(endpoint)?;
        let context = self.build_remote_process_context(input);
        let protocol = self.attach_protocol_for_started_process(
            input,
            &context,
            AcpTransport::Http(client),
            None,
        )?;
        let registration = self.register_started_orchestration_agent(
            input,
            input.descriptor.id.as_str(),
            &context.display_name,
            None,
            &protocol,
        )?;
        let event_task = spawn_event_forwarder(
            self.sender(),
            protocol.events,
            Some(self.live_event_persistence(
                input.session_id,
                &registration.agent_id,
                &input.descriptor.id,
            )),
        );
        if protocol.start.send(()).is_err() {
            protocol.protocol.abort();
            protocol.batcher.abort();
            event_task.abort();
            rollback_registration_best_effort(
                self,
                input.session_id,
                input.acp_id,
                &registration.agent_id,
                "startup_failed",
            );
            return Err(CliErrorKind::workflow_io(format!(
                "ACP protocol task exited before startup for '{}'",
                input.descriptor.id
            ))
            .into());
        }
        let snapshot = started_snapshot(StartedSnapshotInput {
            acp_id: input.acp_id,
            session_id: input.session_id,
            request: input.request,
            agent_id: &registration.agent_id,
            display_name: &registration.display_name,
            supervisor: &context.supervisor,
            project_dir: input.project_dir,
            process_key: input.process_key,
            permission_log_path: context.permission_log_path,
        });
        let process = Arc::new(ActiveAcpProcess::new_remote(
            Arc::clone(&context.supervisor),
            protocol.handle,
            context.prompt_gate,
            context.stderr_tail,
            ActiveAcpTasks {
                protocol: protocol.protocol,
                batcher: protocol.batcher,
                event: event_task,
            },
        ));
        if let Err(error) = self.activate_started_session(
            input,
            snapshot.clone(),
            context.permissions,
            process,
            protocol.disconnects,
            context.supervisor,
        ) {
            rollback_registration_best_effort(
                self,
                input.session_id,
                input.acp_id,
                &registration.agent_id,
                "startup_failed",
            );
            return Err(error);
        }
        self.broadcast("acp_agent_started", &snapshot);
        Ok(snapshot)
    }

    fn build_remote_process_context(&self, input: DescriptorStartInput<'_>) -> StartedProcessContext {
        let supervisor = Arc::new(AcpSessionSupervisor::with_process(
            SupervisedProcess::remote(),
            SupervisionConfig::default()
                .with_prompt_timeout(input.descriptor.prompt_timeout_seconds),
        ));
        let permissions = PermissionBridgeHandle::spawn(
            input.acp_id.to_string(),
            input.session_id.to_string(),
            self.sender(),
        );
        let permission_log_path = input
            .request
            .record_permissions
            .then(|| recording_log_path_for_session(input.session_id));
        let display_name = input
            .request
            .name
            .clone()
            .unwrap_or_else(|| input.descriptor.display_name.clone());
        StartedProcessContext {
            permission_log_path,
            display_name,
            prompt_gate: PromptGate::default(),
            supervisor,
            permissions,
            // No child, so no stderr to tail; an empty tail keeps the snapshot
            // shape identical to a local agent's.
            stderr_tail: SharedStderrTail::spawn(None),
        }
    }
}

/// Build the transport client for `endpoint`, resolving each header value from
/// the environment variable named for it. WebSocket connects cannot carry these
/// headers (the SDK drops them), so a header on a `ws`/`wss` endpoint is a hard
/// error rather than a silent auth failure.
fn build_http_client(endpoint: &AcpEndpoint) -> Result<HttpClient, CliError> {
    if endpoint_is_websocket(&endpoint.url) && !endpoint.headers_env.is_empty() {
        return Err(CliErrorKind::workflow_io(
            "--header-env is not supported over ws/wss because the WebSocket transport drops request headers; use an http/https endpoint for header auth"
                .to_string(),
        )
        .into());
    }
    let mut headers = HeaderMap::new();
    for (name, env_var) in &endpoint.headers_env {
        let value = std::env::var(env_var).map_err(|_| {
            CliErrorKind::workflow_io(format!(
                "header '{name}' needs environment variable '{env_var}', which is not set"
            ))
        })?;
        let header_name = HeaderName::from_bytes(name.as_bytes()).map_err(|error| {
            CliErrorKind::workflow_io(format!("invalid header name '{name}': {error}"))
        })?;
        let mut header_value = HeaderValue::from_str(&value).map_err(|error| {
            CliErrorKind::workflow_io(format!("header '{name}' has an invalid value: {error}"))
        })?;
        header_value.set_sensitive(true);
        // The CLI already rejects case-insensitive duplicates, but a request
        // built any other way (Monitor, HTTP start route) has not, and the
        // normalized HeaderName collapses casing - so guard here too.
        if headers.contains_key(&header_name) {
            return Err(CliErrorKind::workflow_io(format!(
                "header '{name}' is set more than once"
            ))
            .into());
        }
        headers.insert(header_name, header_value);
    }
    let http = reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .map_err(|error| CliErrorKind::workflow_io(format!("build HTTP client: {error}")))?;
    HttpClient::with_client(&endpoint.url, http).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "invalid ACP endpoint '{}': {error}",
            endpoint.url
        )))
    })
}

fn endpoint_is_websocket(url: &str) -> bool {
    url.split_once("://").is_some_and(|(scheme, _)| {
        scheme.eq_ignore_ascii_case("ws") || scheme.eq_ignore_ascii_case("wss")
    })
}

#[cfg(test)]
mod tests {
    use super::{build_http_client, endpoint_is_websocket};
    use harness_protocol::managed_agents::acp::AcpEndpoint;

    fn endpoint(url: &str, headers: &[(&str, &str)]) -> AcpEndpoint {
        AcpEndpoint {
            url: url.to_string(),
            headers_env: headers
                .iter()
                .map(|(name, var)| ((*name).to_string(), (*var).to_string()))
                .collect(),
        }
    }

    #[test]
    fn websocket_scheme_is_detected_case_insensitively() {
        assert!(endpoint_is_websocket("ws://host/acp"));
        assert!(endpoint_is_websocket("WSS://host/acp"));
        assert!(!endpoint_is_websocket("https://host/acp"));
    }

    #[test]
    fn websocket_endpoint_rejects_header_env() {
        let error = build_http_client(&endpoint(
            "wss://acp.example.test",
            &[("Authorization", "HARNESS_TEST_ACP_TOKEN")],
        ))
        .expect_err("ws with headers is rejected");
        assert!(error.to_string().contains("ws/wss"));
    }

    #[test]
    fn missing_header_env_var_names_the_variable() {
        temp_env::with_vars([("HARNESS_TEST_ACP_ABSENT", None::<&str>)], || {
            let error = build_http_client(&endpoint(
                "https://acp.example.test",
                &[("Authorization", "HARNESS_TEST_ACP_ABSENT")],
            ))
            .expect_err("missing env var is an error");
            assert!(error.to_string().contains("HARNESS_TEST_ACP_ABSENT"));
        });
    }

    #[test]
    fn resolves_header_env_and_builds_the_client() {
        temp_env::with_vars(
            [("HARNESS_TEST_ACP_TOKEN", Some("secret-value"))],
            || {
                build_http_client(&endpoint(
                    "https://acp.example.test",
                    &[("Authorization", "HARNESS_TEST_ACP_TOKEN")],
                ))
                .expect("client builds from a resolved env header");
            },
        );
    }

    #[test]
    fn websocket_endpoint_without_headers_builds() {
        build_http_client(&endpoint("wss://acp.example.test", &[]))
            .expect("ws with no headers builds");
    }

    #[test]
    fn duplicate_header_names_are_rejected_after_normalization() {
        temp_env::with_vars(
            [
                ("HARNESS_TEST_ACP_A", Some("a")),
                ("HARNESS_TEST_ACP_B", Some("b")),
            ],
            || {
                let error = build_http_client(&endpoint(
                    "https://acp.example.test",
                    &[
                        ("Authorization", "HARNESS_TEST_ACP_A"),
                        ("authorization", "HARNESS_TEST_ACP_B"),
                    ],
                ))
                .expect_err("case-insensitive duplicate rejected after normalization");
                assert!(error.to_string().contains("more than once"));
            },
        );
    }
}
