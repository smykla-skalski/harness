use std::collections::{BTreeSet, VecDeque};
use std::path::PathBuf;
use std::process::Child;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::daemon::agent_tui::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiLaunchProfile, AgentTuiProcess,
    AgentTuiSnapshotContext, AgentTuiStatus,
};
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};

use super::types::{BridgeCapability, PersistedBridgeConfig};

#[derive(Debug, Clone)]
pub(super) struct ResolvedBridgeConfig {
    pub(super) persisted: PersistedBridgeConfig,
    pub(super) capabilities: BTreeSet<BridgeCapability>,
    pub(super) socket_path: PathBuf,
    pub(super) codex_port: u16,
    pub(super) codex_binary: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeCodexMetadata {
    pub(super) port: u16,
    pub(super) binary_path: String,
    #[serde(default)]
    pub(super) version: Option<String>,
    #[serde(default)]
    pub(super) last_exit_status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAgentTuiMetadata {
    pub(super) active_sessions: usize,
}

#[derive(Debug, Clone)]
pub(super) struct BridgeSnapshotContext {
    pub(super) session_id: String,
    pub(super) agent_id: String,
    pub(super) tui_id: String,
    pub(super) profile: AgentTuiLaunchProfile,
    pub(super) project_dir: PathBuf,
    pub(super) transcript_path: PathBuf,
}

impl BridgeSnapshotContext {
    pub(super) fn borrowed(&self) -> AgentTuiSnapshotContext<'_> {
        AgentTuiSnapshotContext {
            session_id: &self.session_id,
            agent_id: &self.agent_id,
            tui_id: &self.tui_id,
            profile: &self.profile,
            project_dir: &self.project_dir,
            transcript_path: &self.transcript_path,
        }
    }
}

#[derive(Clone)]
pub(super) struct BridgeActiveTui {
    pub(super) process: Arc<AgentTuiProcess>,
    pub(super) stop_flag: Arc<AtomicBool>,
    pub(super) input_worker: AgentTuiInputWorker,
    pub(super) context: BridgeSnapshotContext,
    pub(super) created_at: String,
    pub(super) exit_info: Option<BridgeTuiExitInfo>,
}

#[derive(Debug, Clone)]
pub(super) struct BridgeTuiExitInfo {
    pub(super) status: AgentTuiStatus,
    pub(super) exit_code: Option<u32>,
    pub(super) signal: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeEnvelope {
    pub(super) token: String,
    pub(super) request: BridgeRequest,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub(super) enum BridgeRequest {
    Status,
    Shutdown,
    Reconfigure {
        request: BridgeReconfigureSpec,
    },
    Capability {
        capability: String,
        action: String,
        #[serde(default)]
        payload: Value,
    },
}

pub(super) enum BridgeHandleResult {
    Response(BridgeResponse),
    AttachStream(BridgeResponse, Arc<AgentTuiProcess>, AgentTuiAttachState),
}

impl From<BridgeResponse> for BridgeHandleResult {
    fn from(resp: BridgeResponse) -> Self {
        Self::Response(resp)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeResponse {
    pub(super) ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) payload: Option<Value>,
}

impl BridgeResponse {
    pub(super) fn ok_payload<T: Serialize>(payload: &T) -> Result<Self, CliError> {
        let payload = serde_json::to_value(payload)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        Ok(Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: Some(payload),
        })
    }

    pub(super) const fn empty_ok() -> Self {
        Self {
            ok: true,
            code: None,
            message: None,
            details: None,
            payload: None,
        }
    }

    pub(super) fn error(error: &CliError) -> Self {
        Self {
            ok: false,
            code: Some(error.code().to_string()),
            message: Some(error.message()),
            details: error.details().map(str::to_owned),
            payload: None,
        }
    }
}

pub(super) struct BridgeCodexProcess {
    pub(super) child: Child,
    /// Process group leader id of the spawned codex child.
    ///
    /// Codex is spawned with `process_group(0)` so it heads its own group.
    /// Bridge owns explicit shutdown via `killpg(pgid, SIGTERM)` so codex
    /// dies with bridge instead of getting reparented to launchd and
    /// holding the listening port.
    pub(super) pgid: i32,
    pub(super) endpoint: String,
    pub(super) metadata: BridgeCodexMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CodexEndpointScheme {
    WebSocket,
    SecureWebSocket,
}

impl CodexEndpointScheme {
    pub(super) fn parse(endpoint: &str) -> Option<(Self, &str)> {
        endpoint
            .strip_prefix("ws://")
            .map(|address| (Self::WebSocket, address))
            .or_else(|| {
                endpoint
                    .strip_prefix("wss://")
                    .map(|address| (Self::SecureWebSocket, address))
            })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeReconfigureSpec {
    #[serde(default)]
    pub(super) enable: Vec<BridgeCapability>,
    #[serde(default)]
    pub(super) disable: Vec<BridgeCapability>,
    #[serde(default)]
    pub(super) force: bool,
}

impl BridgeReconfigureSpec {
    pub(super) fn validate(&self) -> Result<(), CliError> {
        if self.enable.is_empty() && self.disable.is_empty() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure requires at least one --enable or --disable flag",
            )
            .into());
        }
        let enable: BTreeSet<_> = self.enable.iter().copied().collect();
        if enable.len() != self.enable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --enable",
            )
            .into());
        }
        let disable: BTreeSet<_> = self.disable.iter().copied().collect();
        if disable.len() != self.disable.len() {
            return Err(CliErrorKind::workflow_parse(
                "bridge reconfigure listed the same capability more than once in --disable",
            )
            .into());
        }
        if let Some(contradiction) = enable.intersection(&disable).next().copied() {
            return Err(CliErrorKind::workflow_parse(format!(
                "bridge reconfigure cannot enable and disable '{}' in one request",
                contradiction.name()
            ))
            .into());
        }
        Ok(())
    }

    #[must_use]
    pub(super) fn enable_set(&self) -> BTreeSet<BridgeCapability> {
        self.enable.iter().copied().collect()
    }

    #[must_use]
    pub(super) fn disable_set(&self) -> BTreeSet<BridgeCapability> {
        self.disable.iter().copied().collect()
    }

    pub(super) fn from_names(
        enable: &[String],
        disable: &[String],
        force: bool,
    ) -> Result<Self, CliError> {
        let enable = enable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let disable = disable
            .iter()
            .map(|name| {
                BridgeCapability::from_name(name).ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!("unsupported bridge capability '{name}'"))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let request = Self {
            enable,
            disable,
            force,
        };
        request.validate()?;
        Ok(request)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct BridgeAcpEventsResponse {
    pub(super) bridge_epoch: String,
    pub(super) continuity: u64,
    pub(super) next_seq: u64,
    pub(super) truncated: bool,
    pub(super) requires_resync: bool,
    pub(super) events: Vec<StreamEvent>,
}

#[derive(Debug)]
pub(super) struct BridgeAcpEventBuffer {
    bridge_epoch: String,
    next_seq: u64,
    continuity: u64,
    events: VecDeque<(u64, StreamEvent)>,
}

impl BridgeAcpEventBuffer {
    pub(super) const MAX_EVENTS: usize = 512;

    #[must_use]
    pub(super) fn new(bridge_epoch: String) -> Self {
        Self {
            bridge_epoch,
            next_seq: 0,
            continuity: 0,
            events: VecDeque::new(),
        }
    }

    // ACP host sessions emit live daemon push events. Sandboxed daemons cannot
    // subscribe directly, so the host bridge keeps a short replay window and
    // sandboxed peers poll by sequence number after reconnect or startup.
    pub(super) fn push(&mut self, event: StreamEvent) {
        self.next_seq = self.next_seq.saturating_add(1);
        self.events.push_back((self.next_seq, event));
        while self.events.len() > Self::MAX_EVENTS {
            let _ = self.events.pop_front();
        }
    }

    pub(super) fn record_lag(&mut self, skipped: u64) {
        if skipped == 0 {
            return;
        }
        self.continuity = self.continuity.saturating_add(1);
    }

    #[must_use]
    pub(super) fn events_since(
        &self,
        after_seq: Option<u64>,
        known_epoch: Option<&str>,
        known_continuity: Option<u64>,
    ) -> BridgeAcpEventsResponse {
        let after_seq = after_seq.unwrap_or_default();
        let oldest_seq = self.events.front().map_or(self.next_seq, |(seq, _)| *seq);
        let evicted_history = self.next_seq > self.events.len() as u64;
        let truncated = after_seq > self.next_seq
            || (after_seq == 0 && evicted_history)
            || (after_seq > 0 && after_seq < oldest_seq.saturating_sub(1));
        let epoch_changed = known_epoch.is_some_and(|epoch| epoch != self.bridge_epoch);
        let continuity_changed =
            known_continuity.is_some_and(|continuity| continuity != self.continuity);
        let events = self
            .events
            .iter()
            .filter(|(seq, _)| *seq > after_seq)
            .map(|(_, event)| event.clone())
            .collect();
        BridgeAcpEventsResponse {
            bridge_epoch: self.bridge_epoch.clone(),
            continuity: self.continuity,
            next_seq: self.next_seq,
            truncated,
            requires_resync: truncated || epoch_changed || continuity_changed,
            events,
        }
    }
}
