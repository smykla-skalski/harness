use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::id as process_id;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::Value;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::protocol::StreamEvent;
use crate::daemon::state::{self, HostBridgeCapabilityManifest};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::acp_rpc::{
    BridgeAcpEventsRequest, BridgeAcpGetRequest, BridgeAcpInspectRequest, BridgeAcpListRequest,
    BridgeAcpReconcileRequest, BridgeAcpResolvePermissionRequest, BridgeAcpStartRequest,
};
use super::bridge_state::{write_bridge_config, write_bridge_state};
use super::client::{
    BridgeAttachRequest, BridgeGetRequest, BridgeInputRequest, BridgeResizeRequest,
};
use super::core::{
    BridgeAcpEventBuffer, BridgeActiveTui, BridgeCodexProcess, BridgeEnvelope, BridgeHandleResult,
    BridgeReconfigureSpec, BridgeRequest, BridgeResponse, ResolvedBridgeConfig,
};
use super::helpers::{parse_bridge_payload, resolve_bridge_config, uptime_from_started_at};
use super::types::{
    AgentTuiStartSpec, BRIDGE_CAPABILITY_ACP, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX,
    BridgeCapability, BridgeState, BridgeStatusReport, PersistedBridgeConfig,
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
    pub(super) acp_runtime: Runtime,
    pub(super) acp_agent_manager: AcpAgentManagerHandle,
    pub(super) acp_events: Arc<Mutex<BridgeAcpEventBuffer>>,
    pub(super) shutdown: AtomicBool,
}

impl BridgeServer {
    pub(super) fn new(
        token: String,
        socket_path: PathBuf,
        desired_config: PersistedBridgeConfig,
        capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
    ) -> Self {
        let acp_runtime = Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build ACP bridge runtime");
        let (acp_sender, mut acp_receiver) = broadcast::channel::<StreamEvent>(256);
        let acp_events = Arc::new(Mutex::new(BridgeAcpEventBuffer::new(format!(
            "bridge-{}",
            Uuid::new_v4()
        ))));
        let acp_events_sink = Arc::clone(&acp_events);
        acp_runtime.spawn(async move {
            loop {
                match acp_receiver.recv().await {
                    Ok(event) => {
                        if let Ok(mut buffer) = acp_events_sink.lock() {
                            buffer.push(event);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        if let Ok(mut buffer) = acp_events_sink.lock() {
                            buffer.record_lag(skipped);
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
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
            acp_runtime,
            acp_agent_manager: AcpAgentManagerHandle::new(acp_sender, Arc::new(OnceLock::new())),
            acp_events,
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
            BRIDGE_CAPABILITY_ACP => self.handle_acp(action, payload),
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
                request.request.validate()?;
                let active = self.active_tui(&request.tui_id)?;
                match (request.request.input(), request.request.sequence()) {
                    (Some(input), None) => active.input_worker.send_input(input)?,
                    (None, Some(sequence)) => active.input_worker.enqueue_sequence(sequence)?,
                    _ => {
                        return Err(CliErrorKind::workflow_parse(
                            "terminal agent input request requires exactly one of 'input' or 'sequence'",
                        )
                        .into());
                    }
                }
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

    pub(super) fn handle_acp(
        &self,
        action: &str,
        payload: Value,
    ) -> Result<BridgeHandleResult, CliError> {
        match action {
            "start" => {
                let request: BridgeAcpStartRequest = parse_bridge_payload(payload)?;
                let snapshot = self.start_acp(
                    &request.session_id,
                    &request.request,
                    request.disable_pooling,
                )?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "list" => {
                let request: BridgeAcpListRequest = parse_bridge_payload(payload)?;
                let snapshots = self.list_acp(&request.session_id)?;
                Ok(BridgeResponse::ok_payload(&snapshots)?.into())
            }
            "inspect" => {
                let request: BridgeAcpInspectRequest = parse_bridge_payload(payload)?;
                let response = self.inspect_acp(request.session_id.as_deref())?;
                Ok(BridgeResponse::ok_payload(&response)?.into())
            }
            "reconcile" => {
                let _: BridgeAcpReconcileRequest = parse_bridge_payload(payload)?;
                let response = self.reconcile_acp()?;
                Ok(BridgeResponse::ok_payload(&response)?.into())
            }
            "get" => {
                let request: BridgeAcpGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.get_acp(&request.acp_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "stop" => {
                let request: BridgeAcpGetRequest = parse_bridge_payload(payload)?;
                let snapshot = self.stop_acp(&request.acp_id)?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "resolve_permission" => {
                let request: BridgeAcpResolvePermissionRequest = parse_bridge_payload(payload)?;
                let snapshot = self.resolve_acp_permission(
                    &request.acp_id,
                    &request.batch_id,
                    &request.decision,
                )?;
                Ok(BridgeResponse::ok_payload(&snapshot)?.into())
            }
            "events_since" => {
                let request: BridgeAcpEventsRequest = parse_bridge_payload(payload)?;
                let response = self.acp_events_since(
                    request.after_seq,
                    request.known_epoch.as_deref(),
                    request.known_continuity,
                )?;
                Ok(BridgeResponse::ok_payload(&response)?.into())
            }
            _ => Err(CliErrorKind::workflow_parse(format!(
                "unsupported acp bridge action '{action}'"
            ))
            .into()),
        }
    }
}
