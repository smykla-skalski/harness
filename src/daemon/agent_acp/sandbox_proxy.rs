use std::thread;
use std::time::Duration;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::service;

use super::manager::{AcpAgentInspectResponse, AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};

const SANDBOX_ACP_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(250);
const SANDBOX_ACP_IDLE_INSPECT_POLLS: usize = 20;

impl AcpAgentManagerHandle {
    pub(super) fn start_via_bridge(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, crate::errors::CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        let snapshot = bridge.acp_start(session_id, request)?;
        self.ensure_sandbox_event_poller();
        Ok(snapshot)
    }

    pub(super) fn resolve_permission_batch_via_bridge(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, crate::errors::CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        let snapshot = bridge.acp_resolve_permission(acp_id, batch_id, decision)?;
        self.ensure_sandbox_event_poller();
        Ok(snapshot)
    }

    pub(super) fn list_via_bridge(
        &self,
        session_id: &str,
    ) -> Result<Vec<AcpAgentSnapshot>, crate::errors::CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        self.ensure_sandbox_event_poller();
        bridge.acp_list(session_id)
    }

    pub(super) fn inspect_via_bridge(&self, session_id: Option<&str>) -> AcpAgentInspectResponse {
        let bridge = match BridgeClient::for_capability(BridgeCapability::Acp) {
            Ok(bridge) => bridge,
            Err(error) => {
                tracing::warn!(%error, "failed to connect to ACP host bridge");
                return AcpAgentInspectResponse { agents: Vec::new() };
            }
        };
        self.ensure_sandbox_event_poller();
        match bridge.acp_inspect(session_id) {
            Ok(response) => response,
            Err(error) => {
                tracing::warn!(%error, "failed to inspect ACP host bridge sessions");
                AcpAgentInspectResponse { agents: Vec::new() }
            }
        }
    }

    pub(super) fn get_via_bridge(
        &self,
        acp_id: &str,
    ) -> Result<AcpAgentSnapshot, crate::errors::CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        self.ensure_sandbox_event_poller();
        bridge.acp_get(acp_id)
    }

    pub(super) fn stop_via_bridge(
        &self,
        acp_id: &str,
    ) -> Result<AcpAgentSnapshot, crate::errors::CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        let snapshot = bridge.acp_stop(acp_id)?;
        self.ensure_sandbox_event_poller();
        Ok(snapshot)
    }

    pub(super) fn shutdown_all_via_bridge(&self) {
        // Once ACP is host-bridged, the bridge owns host lifecycle. A
        // sandboxed daemon shutdown must not tear down those sessions.
    }

    pub(super) fn pending_permission_count_via_bridge(&self, acp_id: &str) -> Option<usize> {
        self.get_via_bridge(acp_id).ok().map(|snapshot| snapshot.pending_permissions)
    }

    pub(super) fn pending_permission_batches_via_bridge(
        &self,
        acp_id: &str,
    ) -> Option<Vec<AcpPermissionBatch>> {
        self.get_via_bridge(acp_id)
            .ok()
            .map(|snapshot| snapshot.pending_permission_batches)
    }

    pub(super) fn live_session_count_via_bridge(&self) -> usize {
        BridgeClient::for_capability(BridgeCapability::Acp)
            .and_then(|bridge| bridge.acp_inspect(None))
            .map_or(0, |response| response.agents.len())
    }

    fn ensure_sandbox_event_poller(&self) {
        if !service::sandboxed_from_env() || self.swap_sandbox_event_poller_running() {
            return;
        }
        let manager = self.clone();
        thread::spawn(move || {
            manager.run_sandbox_event_poller();
            manager.clear_sandbox_event_poller_running();
        });
    }

    fn run_sandbox_event_poller(&self) {
        let mut idle_polls = 0usize;
        loop {
            let bridge = match BridgeClient::for_capability(BridgeCapability::Acp) {
                Ok(bridge) => bridge,
                Err(error) => {
                    tracing::warn!(%error, "stopping ACP sandbox event poller");
                    return;
                }
            };
            let after_seq = self.sandbox_event_cursor();
            match bridge.acp_events_since(after_seq) {
                Ok(response) => {
                    self.set_sandbox_event_cursor(Some(response.next_seq));
                    if response.events.is_empty() {
                        idle_polls = idle_polls.saturating_add(1);
                        if idle_polls >= SANDBOX_ACP_IDLE_INSPECT_POLLS
                            && bridge
                                .acp_inspect(None)
                                .is_ok_and(|inspect| inspect.agents.is_empty())
                        {
                            return;
                        }
                    } else {
                        idle_polls = 0;
                        for event in response.events {
                            let _ = self.sender().send(event);
                        }
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "stopping ACP sandbox event poller after bridge error");
                    return;
                }
            }
            thread::sleep(SANDBOX_ACP_EVENT_POLL_INTERVAL);
        }
    }
}
