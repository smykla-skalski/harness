use std::io::{BufRead, BufReader, ErrorKind, Write as _};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::thread;
use std::time::Instant;
use std::time::Duration;

use fs_err as fs;
use serde::{Deserialize, Serialize, de::DeserializeOwned};

use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentSnapshot, AcpAgentStartRequest, AcpPermissionDecision,
};
use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiSnapshot};
use crate::errors::{CliError, CliErrorKind};

use super::acp_rpc::{
    BridgeAcpEventsRequest, BridgeAcpEventsResponse, BridgeAcpGetRequest,
    BridgeAcpInspectRequest, BridgeAcpListRequest, BridgeAcpResolvePermissionRequest,
    BridgeAcpStartRequest,
};
use super::bridge_state::{LivenessMode, resolve_running_bridge};
use super::core::{BridgeEnvelope, BridgeReconfigureSpec, BridgeRequest, BridgeResponse};
use super::detached::bridge_response_error;
use super::helpers::parse_bridge_payload;
use super::types::{AgentTuiStartSpec, BridgeCapability, BridgeState, BridgeStatusReport};

const BRIDGE_RPC_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
pub struct BridgeClient {
    pub(super) socket_path: PathBuf,
    pub(super) token: String,
}

impl BridgeClient {
    /// Build a bridge client directly from one persisted bridge state record.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge auth token cannot be loaded.
    pub fn from_state(state: &BridgeState) -> Result<Self, CliError> {
        let token = fs::read_to_string(&state.token_path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "read bridge token {}: {error}",
                    state.token_path
                ))
            })?
            .trim()
            .to_string();
        Ok(Self {
            socket_path: PathBuf::from(&state.socket_path),
            token,
        })
    }

    /// Build a bridge client from the persisted running bridge state.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable or the auth token
    /// cannot be loaded.
    pub fn from_state_file() -> Result<Self, CliError> {
        let state = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            .map(|running| running.state)
            .ok_or_else(|| CliErrorKind::workflow_io("bridge is not running"))?;
        Self::from_state(&state)
    }

    /// Build a bridge client for one required capability.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge is unavailable, the capability is
    /// not enabled, or the auth token cannot be loaded.
    pub fn for_capability(capability: BridgeCapability) -> Result<Self, CliError> {
        let running = resolve_running_bridge(LivenessMode::HostAuthoritative)?
            .ok_or_else(|| CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()))?;
        if !running.report.capabilities.contains_key(capability.name()) {
            return Err(
                CliErrorKind::sandbox_feature_disabled(capability.sandbox_feature()).into(),
            );
        }
        Self::from_state(&running.state)
    }

    fn send(&self, request: BridgeRequest) -> Result<BridgeResponse, CliError> {
        let envelope = BridgeEnvelope {
            token: self.token.clone(),
            request,
        };
        let payload = serde_json::to_string(&envelope)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        let mut stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "connect bridge socket {}: {error}",
                self.socket_path.display()
            ))
        })?;
        stream
            .set_read_timeout(Some(BRIDGE_RPC_TIMEOUT))
            .and_then(|()| stream.set_write_timeout(Some(BRIDGE_RPC_TIMEOUT)))
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "configure bridge RPC timeout {}: {error}",
                    self.socket_path.display()
                ))
            })?;
        stream
            .write_all(payload.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .map_err(|error| CliErrorKind::workflow_io(format!("write bridge request: {error}")))?;
        let mut line = String::new();
        BufReader::new(stream)
            .read_line(&mut line)
            .map_err(|error| CliErrorKind::workflow_io(format!("read bridge response: {error}")))?;
        serde_json::from_str(&line).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse bridge response: {error}")).into()
        })
    }

    fn typed_capability_request<T: DeserializeOwned, P: Serialize>(
        &self,
        capability: BridgeCapability,
        action: &str,
        payload: &P,
    ) -> Result<T, CliError> {
        let payload = serde_json::to_value(payload)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        let response = self.send(BridgeRequest::Capability {
            capability: capability.name().to_string(),
            action: action.to_string(),
            payload,
        })?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        serde_json::from_value(payload).map_err(|error| {
            CliErrorKind::workflow_parse(format!("decode bridge payload: {error}")).into()
        })
    }

    /// Ask the running bridge to shut down.
    ///
    /// # Errors
    /// Returns [`CliError`] when the shutdown request fails or the bridge
    /// returns an error response.
    pub fn shutdown(&self) -> Result<(), CliError> {
        let response = self.send(BridgeRequest::Shutdown)?;
        if response.ok {
            return Ok(());
        }
        Err(bridge_response_error(response))
    }

    /// Ask the running bridge for its current status report.
    ///
    /// # Errors
    /// Returns [`CliError`] when the request fails or the bridge returns an
    /// error response.
    pub fn status(&self) -> Result<BridgeStatusReport, CliError> {
        let response = self.send(BridgeRequest::Status)?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        parse_bridge_payload(payload)
    }

    pub(super) fn reconfigure(
        &self,
        request: &BridgeReconfigureSpec,
    ) -> Result<BridgeStatusReport, CliError> {
        let response = self.send(BridgeRequest::Reconfigure {
            request: request.clone(),
        })?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        let payload = response
            .payload
            .ok_or_else(|| CliErrorKind::workflow_io("bridge response omitted payload"))?;
        parse_bridge_payload(payload)
    }

    /// Start one bridge-managed terminal agent session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be encoded or decoded.
    pub fn agent_tui_start(&self, spec: &AgentTuiStartSpec) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(BridgeCapability::AgentTui, "start", spec)
    }

    /// Load the latest snapshot for one bridge-managed terminal agent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_get(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "get",
            &BridgeGetRequest {
                tui_id: tui_id.to_string(),
            },
        )
    }

    /// Send keyboard-like input to one bridge-managed terminal agent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "input",
            &BridgeInputRequest {
                tui_id: tui_id.to_string(),
                request: request.clone(),
            },
        )
    }

    /// Resize one bridge-managed terminal agent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_resize(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "resize",
            &BridgeResizeRequest {
                tui_id: tui_id.to_string(),
                request: *request,
            },
        )
    }

    /// Stop one bridge-managed terminal agent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or the payload
    /// cannot be decoded.
    pub fn agent_tui_stop(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::AgentTui,
            "stop",
            &BridgeGetRequest {
                tui_id: tui_id.to_string(),
            },
        )
    }

    /// Attach to one bridge-managed terminal agent.
    /// Returns the raw socket for streaming output.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request.
    pub fn agent_tui_attach(&self, tui_id: &str) -> Result<UnixStream, CliError> {
        let request = BridgeRequest::Capability {
            capability: BridgeCapability::AgentTui.name().to_string(),
            action: "attach".to_string(),
            payload: serde_json::to_value(BridgeAttachRequest {
                tui_id: tui_id.to_string(),
            })
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?,
        };
        let envelope = BridgeEnvelope {
            token: self.token.clone(),
            request,
        };
        let payload = serde_json::to_string(&envelope)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        let mut stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "connect bridge socket {}: {error}",
                self.socket_path.display()
            ))
        })?;
        stream
            .write_all(payload.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .map_err(|error| CliErrorKind::workflow_io(format!("write bridge request: {error}")))?;

        stream.set_nonblocking(true).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "configure bridge attach handshake {}: {error}",
                self.socket_path.display()
            ))
        })?;
        let mut reader = stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge stream: {error}")))?;
        let mut buf = Vec::new();
        let mut byte = [0u8; 1];
        let deadline = Instant::now() + BRIDGE_RPC_TIMEOUT;
        loop {
            use std::io::Read;
            match reader.read(&mut byte) {
                Ok(0) => break,
                Ok(_) => {
                    let b = byte[0];
                    buf.push(b);
                    if b == b'\n' {
                        break;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(CliErrorKind::workflow_io(format!(
                            "read bridge response timed out after {}s",
                            BRIDGE_RPC_TIMEOUT.as_secs()
                        ))
                        .into());
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => {
                    return Err(CliErrorKind::workflow_io(format!(
                        "read bridge response: {error}"
                    ))
                    .into());
                }
            }
        }
        let line = String::from_utf8(buf).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse bridge response: {error}"))
        })?;
        let response: BridgeResponse = serde_json::from_str(&line).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse bridge response: {error}"))
        })?;
        if !response.ok {
            return Err(bridge_response_error(response));
        }
        stream.set_nonblocking(false).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "restore bridge attach blocking mode {}: {error}",
                self.socket_path.display()
            ))
        })?;
        clear_rpc_timeouts(&stream, &self.socket_path)?;
        Ok(stream)
    }

    pub fn acp_start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "start",
            &BridgeAcpStartRequest {
                session_id: session_id.to_string(),
                request: request.clone(),
            },
        )
    }

    pub fn acp_list(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "list",
            &BridgeAcpListRequest {
                session_id: session_id.to_string(),
            },
        )
    }

    pub fn acp_inspect(
        &self,
        session_id: Option<&str>,
    ) -> Result<AcpAgentInspectResponse, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "inspect",
            &BridgeAcpInspectRequest {
                session_id: session_id.map(ToOwned::to_owned),
            },
        )
    }

    pub fn acp_get(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "get",
            &BridgeAcpGetRequest {
                acp_id: acp_id.to_string(),
            },
        )
    }

    pub fn acp_stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "stop",
            &BridgeAcpGetRequest {
                acp_id: acp_id.to_string(),
            },
        )
    }

    pub fn acp_resolve_permission(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "resolve_permission",
            &BridgeAcpResolvePermissionRequest {
                acp_id: acp_id.to_string(),
                batch_id: batch_id.to_string(),
                decision: decision.clone(),
            },
        )
    }

    pub(crate) fn acp_events_since(
        &self,
        after_seq: Option<u64>,
        known_epoch: Option<&str>,
        known_continuity: Option<u64>,
    ) -> Result<BridgeAcpEventsResponse, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "events_since",
            &BridgeAcpEventsRequest {
                after_seq,
                known_epoch: known_epoch.map(ToOwned::to_owned),
                known_continuity,
            },
        )
    }
}

fn clear_rpc_timeouts(stream: &UnixStream, socket_path: &std::path::Path) -> Result<(), CliError> {
    for result in [
        stream.set_read_timeout(None),
        stream.set_write_timeout(None),
    ] {
        if let Err(error) = result {
            if error.kind() != ErrorKind::InvalidInput {
                return Err(CliErrorKind::workflow_io(format!(
                    "clear bridge RPC timeout {}: {error}",
                    socket_path.display()
                ))
                .into());
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeGetRequest {
    pub(super) tui_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAttachRequest {
    pub(super) tui_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeInputRequest {
    pub(super) tui_id: String,
    pub(super) request: AgentTuiInputRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeResizeRequest {
    pub(super) tui_id: String,
    pub(super) request: AgentTuiResizeRequest,
}
