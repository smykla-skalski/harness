use std::collections::{BTreeMap, BTreeSet};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tokio::sync::broadcast;

use crate::daemon::bridge::{BridgeCapability, BridgeClient};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::CliError;
use crate::workspace::utc_now;

use super::manager::{
    AcpAgentInspectResponse, AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest,
};
use super::permission_bridge::{AcpPermissionBatch, AcpPermissionDecision};
mod incidents;
use incidents::{
    AcpPoolKeyMismatchIncidentPayload, bridge_resync_incident_payload, dedupe_incident_replays,
    emit_bridge_resync_incident, emit_pool_key_mismatch_incidents, incident_key,
    replay_safe_resync_events,
};

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
    ) -> Result<AcpAgentSnapshot, CliError> {
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
    ) -> Result<AcpAgentSnapshot, CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        let snapshot = bridge.acp_resolve_permission(acp_id, batch_id, decision)?;
        self.ensure_sandbox_event_poller();
        Ok(snapshot)
    }

    pub(super) fn list_via_bridge(
        &self,
        session_id: &str,
    ) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        self.ensure_sandbox_event_poller();
        bridge.acp_list(session_id)
    }

    pub(super) fn inspect_via_bridge(&self, session_id: Option<&str>) -> AcpAgentInspectResponse {
        let bridge = match BridgeClient::for_capability(BridgeCapability::Acp) {
            Ok(bridge) => bridge,
            Err(error) => {
                return log_empty_inspect_with_error(
                    &error,
                    "failed to connect to ACP host bridge",
                );
            }
        };
        self.ensure_sandbox_event_poller();
        match bridge.acp_inspect(session_id) {
            Ok(response) => response,
            Err(error) => {
                log_empty_inspect_with_error(&error, "failed to inspect ACP host bridge sessions")
            }
        }
    }

    pub(super) fn get_via_bridge(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        self.ensure_sandbox_event_poller();
        bridge.acp_get(acp_id)
    }

    pub(super) fn stop_via_bridge(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::Acp)?;
        let snapshot = bridge.acp_stop(acp_id)?;
        self.ensure_sandbox_event_poller();
        Ok(snapshot)
    }

    pub(super) fn shutdown_all_via_bridge() {
        // Once ACP is host-bridged, the bridge owns host lifecycle. A
        // sandboxed daemon shutdown must not tear down those sessions.
    }

    pub(super) fn pending_permission_count_via_bridge(&self, acp_id: &str) -> Option<usize> {
        self.get_via_bridge(acp_id)
            .ok()
            .map(|snapshot| snapshot.pending_permissions)
    }

    pub(super) fn pending_permission_batches_via_bridge(
        &self,
        acp_id: &str,
    ) -> Option<Vec<AcpPermissionBatch>> {
        self.get_via_bridge(acp_id)
            .ok()
            .map(|snapshot| snapshot.pending_permission_batches)
    }

    pub(super) fn live_session_count_via_bridge() -> Result<usize, CliError> {
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
        thread::spawn(move || run_sandbox_event_poller_thread(&manager));
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "bridge resync and replay branches dominate the measured complexity"
    )]
    fn run_sandbox_event_poller(&self) {
        let mut idle_polls = 0usize;
        let mut last_protocol_desync: Option<(String, u64, u64, bool, Vec<String>)> = None;
        let mut last_pool_key_mismatch = BTreeMap::<String, Vec<String>>::new();
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
                    let mut replay_events = response.events;
                    if response.requires_resync {
                        tracing::warn!(
                            after_seq,
                            bridge_epoch = %response_epoch,
                            continuity = response_continuity,
                            next_seq = response.next_seq,
                            truncated = response.truncated,
                            "ACP bridge event continuity changed; forcing authoritative resync"
                        );
                        let inspect = bridge.acp_inspect(None);
                        let affected_logical_session_ids = inspect.as_ref().map_or_else(
                            |_| {
                                self.sandbox_known_sessions()
                                    .into_iter()
                                    .collect::<Vec<_>>()
                            },
                            |value| reconcile_sessions(self.sandbox_known_sessions(), value),
                        );
                        let payload = bridge_resync_incident_payload(
                            response_epoch.clone(),
                            response_continuity,
                            response.next_seq,
                            response.truncated,
                            affected_logical_session_ids,
                        );
                        let current_desync = incident_key(&payload);
                        if last_protocol_desync.as_ref() != Some(&current_desync) {
                            emit_bridge_resync_incident(&self.sender(), &payload);
                            last_protocol_desync = Some(current_desync);
                        }
                        match self.reconcile_sandbox_state(
                            &bridge,
                            inspect.ok(),
                            &mut last_pool_key_mismatch,
                        ) {
                            Ok(true) => idle_polls = 0,
                            Ok(false) => {
                                tracing::warn!(
                                    "ACP sandbox reconcile incomplete after snapshot fetch failures; retrying without cursor advance"
                                );
                                thread::sleep(SANDBOX_ACP_EVENT_ERROR_BACKOFF);
                                continue;
                            }
                            Err(error) => {
                                tracing::warn!(%error, "ACP sandbox reconcile failed; retrying");
                                thread::sleep(SANDBOX_ACP_EVENT_ERROR_BACKOFF);
                                continue;
                            }
                        }
                        // After authoritative reconcile, replay only timeline batches.
                        // State-mutating ACP events can be stale relative to reconcile.
                        replay_events =
                            dedupe_incident_replays(replay_safe_resync_events(replay_events));
                    } else {
                        last_protocol_desync = None;
                    }
                    self.set_sandbox_event_epoch(Some(response_epoch));
                    self.set_sandbox_event_continuity(Some(response_continuity));
                    self.set_sandbox_event_cursor(Some(response.next_seq));
                    if self.handle_sandbox_replay_events(&bridge, replay_events, &mut idle_polls) {
                        return;
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

    #[expect(
        clippy::cognitive_complexity,
        reason = "sandbox ACP reconcile must merge snapshot fetch failures with session fanout"
    )]
    fn reconcile_sandbox_state(
        &self,
        bridge: &BridgeClient,
        inspect: Option<AcpAgentInspectResponse>,
        last_pool_key_mismatch: &mut BTreeMap<String, Vec<String>>,
    ) -> Result<bool, CliError> {
        let inspect = inspect.unwrap_or(bridge.acp_inspect(None)?);
        let mut agents_by_session = BTreeMap::<String, Vec<AcpAgentSnapshot>>::new();
        let mut current_sessions = BTreeSet::new();
        let mut had_fetch_failures = false;
        for agent in &inspect.agents {
            current_sessions.insert(agent.session_id.clone());
            match bridge.acp_get(&agent.acp_id) {
                Ok(snapshot) => {
                    agents_by_session
                        .entry(snapshot.session_id.clone())
                        .or_default()
                        .push(snapshot);
                }
                Err(error) => {
                    had_fetch_failures = true;
                    tracing::warn!(
                        %error,
                        session_id = %agent.session_id,
                        acp_id = %agent.acp_id,
                        "ACP sandbox reconcile skipped one agent after snapshot fetch failed"
                    );
                }
            }
        }
        if had_fetch_failures {
            return Ok(false);
        }
        for session_id in &current_sessions {
            let process_keys = distinct_process_keys_for_session(&inspect, session_id);
            maybe_emit_pool_key_mismatch_incident(
                &self.sender(),
                last_pool_key_mismatch,
                session_id,
                process_keys,
            );
        }
        last_pool_key_mismatch.retain(|session_id, _| current_sessions.contains(session_id));
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
        Ok(true)
    }

    fn remember_sandbox_session(&self, session_id: &str) {
        let mut sessions = self.sandbox_known_sessions();
        sessions.insert(session_id.to_string());
        self.set_sandbox_known_sessions(sessions);
    }

    fn handle_sandbox_replay_events(
        &self,
        bridge: &BridgeClient,
        replay_events: Vec<StreamEvent>,
        idle_polls: &mut usize,
    ) -> bool {
        if replay_events.is_empty() {
            *idle_polls = idle_polls.saturating_add(1);
            return *idle_polls >= SANDBOX_ACP_IDLE_INSPECT_POLLS
                && bridge
                    .acp_inspect(None)
                    .is_ok_and(|inspect| inspect.agents.is_empty());
        }
        *idle_polls = 0;
        for event in replay_events {
            if let Some(session_id) = event.session_id.as_ref() {
                self.remember_sandbox_session(session_id);
            }
            let _ = self.sender().send(event);
        }
        false
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_empty_inspect_with_error(error: &CliError, message: &str) -> AcpAgentInspectResponse {
    tracing::warn!(%error, "{message}");
    AcpAgentInspectResponse { agents: Vec::new() }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn run_sandbox_event_poller_thread(manager: &AcpAgentManagerHandle) {
    let result = catch_unwind(AssertUnwindSafe(|| manager.run_sandbox_event_poller()));
    manager.clear_sandbox_event_poller_running();
    if result.is_err() {
        tracing::warn!("ACP sandbox event poller panicked; it can be restarted");
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

fn reconcile_sessions(
    known_sessions: BTreeSet<String>,
    inspect: &AcpAgentInspectResponse,
) -> Vec<String> {
    known_sessions
        .into_iter()
        .chain(inspect.agents.iter().map(|agent| agent.session_id.clone()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
}

fn distinct_process_keys_for_session(
    inspect: &AcpAgentInspectResponse,
    session_id: &str,
) -> Vec<String> {
    inspect
        .agents
        .iter()
        .filter(|agent| agent.session_id == session_id)
        .map(|agent| agent.process_key.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn maybe_emit_pool_key_mismatch_incident(
    sender: &broadcast::Sender<StreamEvent>,
    last_pool_key_mismatch: &mut BTreeMap<String, Vec<String>>,
    session_id: &str,
    process_keys: Vec<String>,
) {
    if process_keys.len() > 1 {
        let changed = last_pool_key_mismatch.get(session_id) != Some(&process_keys);
        last_pool_key_mismatch.insert(session_id.to_string(), process_keys.clone());
        if changed {
            emit_pool_key_mismatch_incidents(
                sender,
                &AcpPoolKeyMismatchIncidentPayload {
                    kind: "pool_key_mismatch".to_string(),
                    observed_process_keys: process_keys,
                    affected_logical_session_ids: vec![session_id.to_string()],
                },
            );
        }
    } else {
        last_pool_key_mismatch.remove(session_id);
    }
}

#[cfg(test)]
mod tests;
