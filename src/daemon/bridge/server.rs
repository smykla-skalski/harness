use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::id as process_id;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::daemon::state::{self, HostBridgeCapabilityManifest};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::bridge_state::{write_bridge_config, write_bridge_state};
use super::client::{
    BridgeAttachRequest, BridgeGetRequest, BridgeInputRequest, BridgeResizeRequest,
};
use super::core::{
    BridgeActiveTui, BridgeCodexProcess, BridgeEnvelope, BridgeHandleResult, BridgeReconfigureSpec,
    BridgeRequest, BridgeResponse, ResolvedBridgeConfig,
};
use super::helpers::{parse_bridge_payload, resolve_bridge_config, uptime_from_started_at};
use super::types::{
    AgentTuiStartSpec, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX, BridgeCapability,
    BridgeState, BridgeStatusReport, PersistedBridgeConfig,
};

pub(super) struct BridgeServer {
    pub(super) token: String,
    pub(super) socket_path: PathBuf,
    pub(super) pid: u32,
    pub(super) started_at: String,
    pub(super) token_path: String,
    pub(super) desired_config: Mutex<PersistedBridgeConfig>,
    pub(super) capabilities: Mutex<BTreeMap<String, HostBridgeCapabilityManifest>>,
    pub(super) active_tuis: Mutex<BTreeMap<String, BridgeActiveTui>>,
    pub(super) codex: Mutex<Option<BridgeCodexProcess>>,
    pub(super) shutdown: AtomicBool,
}

impl BridgeServer {
    pub(super) fn new(
        token: String,
        socket_path: PathBuf,
        desired_config: PersistedBridgeConfig,
        capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
    ) -> Self {
        Self {
            token,
            socket_path,
            pid: process_id(),
            started_at: utc_now(),
            token_path: state::auth_token_path().display().to_string(),
            desired_config: Mutex::new(desired_config),
            capabilities: Mutex::new(capabilities),
            active_tuis: Mutex::new(BTreeMap::new()),
            codex: Mutex::new(None),
            shutdown: AtomicBool::new(false),
        }
    }

    pub(super) fn state(&self) -> Result<BridgeState, CliError> {
        Ok(BridgeState {
            socket_path: self.socket_path.display().to_string(),
            pid: self.pid,
            started_at: self.started_at.clone(),
            token_path: self.token_path.clone(),
            capabilities: self.capabilities()?.clone(),
        })
    }

    pub(super) fn persist_state(&self) -> Result<(), CliError> {
        write_bridge_state(&self.state()?)
    }

    pub(super) fn status_report(&self) -> Result<BridgeStatusReport, CliError> {
        Ok(BridgeStatusReport {
            running: true,
            socket_path: Some(self.socket_path.display().to_string()),
            pid: Some(self.pid),
            started_at: Some(self.started_at.clone()),
            uptime_seconds: uptime_from_started_at(&self.started_at),
            capabilities: self.capabilities()?.clone(),
        })
    }

    pub(super) fn handle(self: &Arc<Self>, envelope: BridgeEnvelope) -> BridgeHandleResult {
        if envelope.token != self.token {
            let error = CliError::from(CliErrorKind::workflow_io("bridge token mismatch"));
            return BridgeResponse::error(&error).into();
        }
        match self.handle_authorized(envelope.request) {
            Ok(response) => response,
            Err(error) => BridgeResponse::error(&error).into(),
        }
    }

    pub(super) fn handle_authorized(
        self: &Arc<Self>,
        request: BridgeRequest,
    ) -> Result<BridgeHandleResult, CliError> {
        match request {
            BridgeRequest::Status => Ok(BridgeResponse::ok_payload(&self.status_report()?)?.into()),
            BridgeRequest::Shutdown => {
                self.shutdown.store(true, Ordering::SeqCst);
                Ok(BridgeResponse::empty_ok().into())
            }
            BridgeRequest::Reconfigure { request } => {
                let report = self.reconfigure(&request)?;
                Ok(BridgeResponse::ok_payload(&report)?.into())
            }
            BridgeRequest::Capability {
                capability,
                action,
                payload,
            } => self.handle_capability(&capability, &action, payload),
        }
    }

    pub(super) fn reconfigure(
        self: &Arc<Self>,
        request: &BridgeReconfigureSpec,
    ) -> Result<BridgeStatusReport, CliError> {
        request.validate()?;

        let enable = request.enable_set();
        let disable = request.disable_set();

        let current_desired = self.desired_config()?.clone();
        let mut next_desired = current_desired.clone();
        let mut next_capabilities = current_desired.capabilities_set();
        for capability in &enable {
            next_capabilities.insert(*capability);
        }
        for capability in &disable {
            next_capabilities.remove(capability);
        }
        next_desired.capabilities = next_capabilities.into_iter().collect();

        let resolved_next = resolve_bridge_config(next_desired.clone())?;
        self.apply_capability_changes(&enable, &disable, request.force, &resolved_next)?;

        *self.desired_config()? = next_desired.clone();
        write_bridge_config(&next_desired)?;
        Self::sync_launch_agent_if_installed()?;
        self.status_report()
    }

    pub(super) fn apply_capability_changes(
        self: &Arc<Self>,
        enable: &BTreeSet<BridgeCapability>,
        disable: &BTreeSet<BridgeCapability>,
        force: bool,
        resolved_next: &ResolvedBridgeConfig,
    ) -> Result<(), CliError> {
        let current_enabled: BTreeSet<_> = self
            .capabilities()?
            .keys()
            .filter_map(|name| BridgeCapability::from_name(name))
            .collect();

        for capability in disable {
            if current_enabled.contains(capability) {
                self.pre_disable_check(*capability, force)?;
            }
        }

        for capability in enable {
            if self.should_enable_capability(*capability, &current_enabled)? {
                self.enable_capability(*capability, resolved_next)?;
            }
        }
        for capability in disable {
            if current_enabled.contains(capability) {
                self.disable_capability(*capability, force)?;
            }
        }
        Ok(())
    }

    pub(super) fn handle_capability(
        &self,
        capability: &str,
        action: &str,
        payload: Value,
    ) -> Result<BridgeHandleResult, CliError> {
        match capability {
            BRIDGE_CAPABILITY_AGENT_TUI => self.handle_agent_tui(action, payload),
            BRIDGE_CAPABILITY_CODEX => Err(CliErrorKind::workflow_parse(format!(
                "bridge capability '{capability}' does not support '{action}' operations"
            ))
            .into()),
            _ => Err(CliErrorKind::workflow_parse(format!(
                "unsupported bridge capability '{capability}'"
            ))
            .into()),
        }
    }

    pub(super) fn handle_agent_tui(
        &self,
        action: &str,
        payload: Value,
    ) -> Result<BridgeHandleResult, CliError> {
        match action {
            "start" => {
                let spec: AgentTuiStartSpec = parse_bridge_payload(payload)?;
                let snapshot = self.start_agent_tui(spec)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "attach" => {
                let request: BridgeAttachRequest = parse_bridge_payload(payload)?;
                let (process, rx) = self.attach_agent_tui(&request.tui_id)?;
                Ok(BridgeHandleResult::AttachStream(
                    BridgeResponse::empty_ok(),
                    process,
                    rx,
                ))
            }
            "get" => {
                let request: BridgeGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "input" => {
                let request: BridgeInputRequest = parse_bridge_payload(payload)?;
                let process = self.active_tui(&request.tui_id)?.process;
                process.send_input(&request.request.input)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "resize" => {
                let request: BridgeResizeRequest = parse_bridge_payload(payload)?;
                let process = self.active_tui(&request.tui_id)?.process;
                process.resize(request.request.size()?)?;
                let snapshot = self.get_agent_tui(&request.tui_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "stop" => {
                let request: BridgeGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.stop_agent_tui(&request.tui_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            _ => Err(CliErrorKind::workflow_parse(format!(
                "unsupported agent-tui bridge action '{action}'"
            ))
            .into()),
        }
    }
}
