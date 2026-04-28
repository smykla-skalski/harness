use std::collections::{BTreeMap, BTreeSet};
use std::thread;
use std::time::Duration;

use serde::Serialize;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::manager::{AcpAgentInspectResponse, AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};

const SANDBOX_ACP_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(250);
const SANDBOX_ACP_EVENT_ERROR_BACKOFF: Duration = Duration::from_secs(1);
const SANDBOX_ACP_IDLE_INSPECT_POLLS: usize = 20;

#[derive(Serialize)]
struct AcpAgentsReconciledPayload {
    session_id: String,
    agents: Vec<AcpAgentSnapshot>,
}

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

    pub(super) fn live_session_count_via_bridge(&self) -> Result<usize, CliError> {
        BridgeClient::for_capability(BridgeCapability::Acp)
            .and_then(|bridge| bridge.acp_inspect(None))
            .map(|response| {
                response
                    .agents
                    .into_iter()
                    .filter(|agent| agent.watchdog_state == "active")
                    .count()
            })
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
                    tracing::warn!(%error, "ACP sandbox event poller failed to connect; retrying");
                    thread::sleep(SANDBOX_ACP_EVENT_ERROR_BACKOFF);
                    continue;
                }
            };
            let after_seq = self.sandbox_event_cursor();
            let known_epoch = self.sandbox_event_epoch();
            let known_continuity = self.sandbox_event_continuity();
            match bridge.acp_events_since(after_seq, known_epoch.as_deref(), known_continuity) {
                Ok(response) => {
                    let response_epoch = response.bridge_epoch.clone();
                    let response_continuity = response.continuity;
                    if response.requires_resync {
                        tracing::warn!(
                            after_seq,
                            bridge_epoch = %response_epoch,
                            continuity = response_continuity,
                            next_seq = response.next_seq,
                            truncated = response.truncated,
                            "ACP bridge event continuity changed; forcing authoritative resync"
                        );
                        match self.reconcile_sandbox_state(&bridge) {
                            Ok(()) => idle_polls = 0,
                            Err(error) => {
                                tracing::warn!(%error, "ACP sandbox reconcile failed; retrying");
                                thread::sleep(SANDBOX_ACP_EVENT_ERROR_BACKOFF);
                                continue;
                            }
                        }
                    }
                    self.set_sandbox_event_epoch(Some(response_epoch));
                    self.set_sandbox_event_continuity(Some(response_continuity));
                    self.set_sandbox_event_cursor(Some(response.next_seq));
                    if response.requires_resync || response.events.is_empty() {
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
                            if let Some(session_id) = event.session_id.as_ref() {
                                self.remember_sandbox_session(session_id);
                            }
                            let _ = self.sender().send(event);
                        }
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "ACP sandbox event poller hit bridge error; retrying");
                    thread::sleep(SANDBOX_ACP_EVENT_ERROR_BACKOFF);
                    continue;
                }
            }
            thread::sleep(SANDBOX_ACP_EVENT_POLL_INTERVAL);
        }
    }

    fn reconcile_sandbox_state(&self, bridge: &BridgeClient) -> Result<(), CliError> {
        let inspect = bridge.acp_inspect(None)?;
        let mut agents_by_session = BTreeMap::<String, Vec<AcpAgentSnapshot>>::new();
        let mut current_sessions = BTreeSet::new();
        for snapshot in inspect
            .agents
            .iter()
            .map(|agent| bridge.acp_get(&agent.acp_id))
            .collect::<Result<Vec<_>, _>>()?
        {
            current_sessions.insert(snapshot.session_id.clone());
            agents_by_session
                .entry(snapshot.session_id.clone())
                .or_default()
                .push(snapshot);
        }
        let reconciled_sessions = self
            .sandbox_known_sessions()
            .into_iter()
            .chain(current_sessions.iter().cloned())
            .collect::<BTreeSet<_>>();
        for session_id in reconciled_sessions {
            let payload = AcpAgentsReconciledPayload {
                session_id: session_id.clone(),
                agents: agents_by_session.remove(&session_id).unwrap_or_default(),
            };
            if let Some(event) = reconciled_event(&payload) {
                let _ = self.sender().send(event);
            }
        }
        self.set_sandbox_known_sessions(current_sessions);
        Ok(())
    }

    fn remember_sandbox_session(&self, session_id: &str) {
        let mut sessions = self.sandbox_known_sessions();
        sessions.insert(session_id.to_string());
        self.set_sandbox_known_sessions(sessions);
    }
}

fn reconciled_event(payload: &AcpAgentsReconciledPayload) -> Option<StreamEvent> {
    Some(StreamEvent {
        event: "acp_agents_reconciled".to_string(),
        recorded_at: utc_now(),
        session_id: Some(payload.session_id.clone()),
        payload: serde_json::to_value(payload).ok()?,
    })
}
