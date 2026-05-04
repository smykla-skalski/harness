use std::collections::BTreeSet;
use std::env;
use std::sync::Arc;
use tokio::time::Instant;

use super::{AcpAgentManagerHandle, AcpAgentSnapshot, ActiveAcpSession, PROCESS_KEY_BACKOFF};
use crate::agents::kind::DisconnectReason;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::AgentStatus;

const ACP_PROCESS_FAULT_POLICY_ENV: &str = "HARNESS_ACP_PROCESS_FAULT_POLICY";

impl AcpAgentManagerHandle {
    pub(super) fn process_fault_events_locked(
        &self,
        snapshot: &AcpAgentSnapshot,
        event: StreamEvent,
    ) -> Result<Vec<StreamEvent>, CliError> {
        let (affected_session_ids, sibling_snapshots) =
            self.disconnect_process_siblings(snapshot)?;
        for sibling_snapshot in sibling_snapshots {
            self.sync_orchestration_disconnect_best_effort(&sibling_snapshot);
        }
        self.remove_process_if_empty(&snapshot.process_key)?;
        let event = self.apply_process_fault_policy(snapshot, event)?;
        Ok(process_fault_fanout_events(event, affected_session_ids))
    }

    fn sessions_for_process_key(
        &self,
        process_key: &str,
    ) -> Result<Vec<Arc<ActiveAcpSession>>, CliError> {
        Ok(self
            .sessions_guard()?
            .values()
            .filter(|session| session.process_key() == process_key)
            .cloned()
            .collect())
    }

    fn disconnect_process_siblings(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) -> Result<(Vec<String>, Vec<AcpAgentSnapshot>), CliError> {
        let AgentStatus::Disconnected { reason, .. } = &snapshot.status else {
            return Ok((vec![snapshot.session_id.clone()], Vec::new()));
        };
        let mut affected = BTreeSet::new();
        let mut disconnected_siblings = Vec::new();
        for session in self.sessions_for_process_key(&snapshot.process_key)? {
            let sibling = session.snapshot_with_live_counts();
            if sibling.acp_id == snapshot.acp_id || !sibling.status.is_disconnected() {
                affected.insert(sibling.session_id.clone());
            }
            if sibling.acp_id != snapshot.acp_id && !sibling.status.is_disconnected() {
                session.disconnect(reason.clone(), false);
                disconnected_siblings.push(session.snapshot_with_live_counts());
            }
        }
        Ok((affected.into_iter().collect(), disconnected_siblings))
    }

    fn apply_process_fault_policy(
        &self,
        snapshot: &AcpAgentSnapshot,
        mut event: StreamEvent,
    ) -> Result<StreamEvent, CliError> {
        if !process_fault_policy_enabled() {
            return Ok(event);
        }
        let (backoff_applied, quarantine_applied) = self.record_process_fault(snapshot)?;
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
        Ok(event)
    }

    pub(in crate::daemon::agent_acp) fn ensure_process_key_start_allowed(
        &self,
        process_key: &str,
    ) -> Result<(), CliError> {
        if let Some(until) = self
            .process_key_backoff_until_guard()?
            .get(process_key)
            .copied()
            && until > Instant::now()
        {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "ACP process key is in backoff after recent faults: {process_key}"
            ))
            .into());
        }
        if self.quarantined_process_keys_guard()?.contains(process_key) {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "ACP process key is quarantined after repeated faults: {process_key}"
            ))
            .into());
        }
        Ok(())
    }

    fn record_process_fault(&self, snapshot: &AcpAgentSnapshot) -> Result<(bool, bool), CliError> {
        let AgentStatus::Disconnected { reason, .. } = &snapshot.status else {
            return Ok((false, false));
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
            return Ok((false, false));
        }
        let process_key = fault_policy_process_key(&snapshot.process_key);
        self.process_key_backoff_until_guard()?
            .insert(process_key.clone(), Instant::now() + PROCESS_KEY_BACKOFF);
        let mut failures = self.process_key_failures_guard()?;
        let failure_count = failures.entry(process_key.clone()).or_insert(0);
        *failure_count = failure_count.saturating_add(1);
        if *failure_count < 3 {
            return Ok((true, false));
        }
        drop(failures);
        let quarantined = self.quarantined_process_keys_guard()?.insert(process_key);
        Ok((true, quarantined))
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

fn fault_policy_process_key(process_key: &str) -> String {
    if let Some((canonical, acp_id)) = process_key.rsplit_once(":isolated:")
        && acp_id.starts_with("agent-acp-")
    {
        return canonical.to_string();
    }
    process_key.to_string()
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
