use std::collections::BTreeSet;
use std::env;
use std::sync::Arc;
use std::time::Instant;

use super::{AcpAgentManagerHandle, AcpAgentSnapshot, ActiveAcpSession, PROCESS_KEY_BACKOFF};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;

const ACP_PROCESS_FAULT_POLICY_ENV: &str = "HARNESS_ACP_PROCESS_FAULT_POLICY";

impl AcpAgentManagerHandle {
    pub(super) fn process_fault_events(
        &self,
        snapshot: &AcpAgentSnapshot,
        event: StreamEvent,
    ) -> Vec<StreamEvent> {
        let _lifecycle = self
            .state
            .process_lifecycle
            .lock()
            .expect("ACP process lifecycle lock");
        self.process_fault_events_locked(snapshot, event)
    }

    pub(super) fn process_fault_events_locked(
        &self,
        snapshot: &AcpAgentSnapshot,
        event: StreamEvent,
    ) -> Vec<StreamEvent> {
        let affected_session_ids = self.disconnect_process_siblings(snapshot);
        self.remove_process_if_empty(&snapshot.process_key);
        let event = self.apply_process_fault_policy(snapshot, event);
        process_fault_fanout_events(event, affected_session_ids)
    }

    fn sessions_for_process_key(&self, process_key: &str) -> Vec<Arc<ActiveAcpSession>> {
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .filter(|session| session.process_key() == process_key)
            .cloned()
            .collect()
    }

    fn disconnect_process_siblings(&self, snapshot: &AcpAgentSnapshot) -> Vec<String> {
        let AgentStatus::Disconnected { reason, .. } = &snapshot.status else {
            return vec![snapshot.session_id.clone()];
        };
        let mut affected = BTreeSet::new();
        for session in self.sessions_for_process_key(&snapshot.process_key) {
            let sibling = session.snapshot_with_live_counts();
            if sibling.acp_id == snapshot.acp_id || !sibling.status.is_disconnected() {
                affected.insert(sibling.session_id.clone());
            }
            if sibling.acp_id != snapshot.acp_id && !sibling.status.is_disconnected() {
                session.disconnect(reason.clone(), false);
            }
        }
        affected.into_iter().collect()
    }

    fn apply_process_fault_policy(
        &self,
        snapshot: &AcpAgentSnapshot,
        mut event: StreamEvent,
    ) -> StreamEvent {
        if !process_fault_policy_enabled() {
            return event;
        }
        let (backoff_applied, quarantine_applied) = self.record_process_fault(snapshot);
        if let serde_json::Value::Object(payload) = &mut event.payload {
            payload.insert(
                "restart_applied".to_string(),
                serde_json::Value::Bool(false),
            );
            payload.insert(
                "backoff_applied".to_string(),
                serde_json::Value::Bool(backoff_applied),
            );
            payload.insert(
                "quarantine_applied".to_string(),
                serde_json::Value::Bool(quarantine_applied),
            );
        }
        event
    }

    fn record_process_fault(&self, snapshot: &AcpAgentSnapshot) -> (bool, bool) {
        let AgentStatus::Disconnected { reason, .. } = &snapshot.status else {
            return (false, false);
        };
        if !matches!(
            reason,
            DisconnectReason::ProcessExited { .. }
                | DisconnectReason::TransportClosed
                | DisconnectReason::StdioClosed
                | DisconnectReason::InitializeTimeout
                | DisconnectReason::PromptTimeout
                | DisconnectReason::WatchdogFired
        ) {
            return (false, false);
        }
        self.state
            .process_key_backoff_until
            .lock()
            .expect("ACP process key backoff lock")
            .insert(
                snapshot.process_key.clone(),
                Instant::now() + PROCESS_KEY_BACKOFF,
            );
        let mut failures = self
            .state
            .process_key_failures
            .lock()
            .expect("ACP process key failures lock");
        let failure_count = failures.entry(snapshot.process_key.clone()).or_insert(0);
        *failure_count = failure_count.saturating_add(1);
        if *failure_count < 3 {
            return (true, false);
        }
        drop(failures);
        let quarantined = self
            .state
            .quarantined_process_keys
            .lock()
            .expect("ACP quarantined process keys lock")
            .insert(snapshot.process_key.clone());
        (true, quarantined)
    }
}

pub(in crate::daemon::agent_acp) fn process_fault_policy_enabled() -> bool {
    env::var(ACP_PROCESS_FAULT_POLICY_ENV).map_or(true, |value| {
        !matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "disabled"
        )
    })
}

fn process_fault_fanout_events(
    mut event: StreamEvent,
    affected_session_ids: Vec<String>,
) -> Vec<StreamEvent> {
    if let serde_json::Value::Object(payload) = &mut event.payload {
        payload.insert(
            "affected_logical_session_ids".to_string(),
            serde_json::Value::Array(
                affected_session_ids
                    .into_iter()
                    .map(serde_json::Value::String)
                    .collect(),
            ),
        );
    }
    let session_ids = affected_logical_session_ids(&event);
    if session_ids.is_empty() {
        return vec![event];
    }
    session_ids
        .into_iter()
        .map(|session_id| {
            let mut event = event.clone();
            event.session_id = Some(session_id);
            event
        })
        .collect()
}

fn affected_logical_session_ids(event: &StreamEvent) -> Vec<String> {
    event
        .payload
        .get("affected_logical_session_ids")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_str().map(ToOwned::to_owned))
        .collect()
}
