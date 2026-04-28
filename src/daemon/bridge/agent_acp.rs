use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentSnapshot, AcpAgentStartRequest, AcpPermissionDecision,
};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::errors::{CliError, CliErrorKind};

use super::core::{BridgeAcpEventsResponse, BridgeAcpMetadata};
use super::helpers::stringify_metadata_map;
use super::server::BridgeServer;
use super::types::{BRIDGE_CAPABILITY_ACP, BridgeCapability};

impl BridgeServer {
    pub(super) fn start_acp(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.ensure_acp_capability()?;
        let snapshot = self.with_acp_runtime(|| self.acp_agent_manager.start(session_id, request))?;
        self.update_acp_metadata()?;
        Ok(snapshot)
    }

    pub(super) fn list_acp(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        self.ensure_acp_capability()?;
        self.with_acp_runtime(|| self.acp_agent_manager.list(session_id))
    }

    pub(super) fn inspect_acp(
        &self,
        session_id: Option<&str>,
    ) -> Result<AcpAgentInspectResponse, CliError> {
        self.ensure_acp_capability()?;
        self.with_acp_runtime(|| Ok(self.acp_agent_manager.inspect(session_id)))
    }

    pub(super) fn get_acp(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.ensure_acp_capability()?;
        self.with_acp_runtime(|| self.acp_agent_manager.get(acp_id))
    }

    pub(super) fn stop_acp(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.ensure_acp_capability()?;
        let snapshot = self.with_acp_runtime(|| self.acp_agent_manager.stop(acp_id))?;
        self.update_acp_metadata()?;
        Ok(snapshot)
    }

    pub(super) fn resolve_acp_permission(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.ensure_acp_capability()?;
        self.with_acp_runtime(|| {
            self.acp_agent_manager
                .resolve_permission_batch(acp_id, batch_id, decision)
        })
    }

    pub(super) fn acp_events_since(
        &self,
        after_seq: Option<u64>,
    ) -> Result<BridgeAcpEventsResponse, CliError> {
        let buffer = self.acp_events.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge ACP event buffer lock poisoned: {error}"))
        })?;
        Ok(buffer.events_since(after_seq))
    }

    pub(super) fn update_acp_metadata(&self) -> Result<(), CliError> {
        let metadata = BridgeAcpMetadata {
            active_sessions: self.acp_agent_manager.count_live_sessions(),
        };
        let manifest = HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "unix".to_string(),
            endpoint: Some(self.socket_path.display().to_string()),
            metadata: stringify_metadata_map(&metadata),
        };
        self.capabilities()?
            .insert(BRIDGE_CAPABILITY_ACP.to_string(), manifest);
        self.persist_state()
    }

    pub(super) fn with_acp_runtime<T>(
        &self,
        action: impl FnOnce() -> Result<T, CliError>,
    ) -> Result<T, CliError> {
        let runtime = self.acp_runtime.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge ACP runtime lock poisoned: {error}"))
        })?;
        runtime.block_on(async move { action() })
    }

    fn ensure_acp_capability(&self) -> Result<(), CliError> {
        if self.capabilities()?.contains_key(BRIDGE_CAPABILITY_ACP) {
            return Ok(());
        }
        Err(CliErrorKind::sandbox_feature_disabled(BridgeCapability::Acp.sandbox_feature()).into())
    }
}
