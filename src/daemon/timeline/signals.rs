use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use crate::agents::runtime::signal::{
    Signal, SignalAck, read_acknowledged_signals, read_acknowledgments,
};
use crate::agents::runtime::signal_session_keys;
use crate::errors::CliError;
use crate::session::types::SessionState;

use super::super::index;
use super::super::protocol::TimelineEntry;
use super::summary::signal_ack_summary;
use super::{TimelinePayloadScope, timeline_payload};

#[derive(Debug, Clone, serde::Serialize)]
pub(super) struct LoggedSignal {
    pub(super) agent_id: String,
    pub(super) command: String,
}

pub(super) fn signal_ack_entries(
    state: &SessionState,
    context_root: &Path,
    sent_signals: &BTreeMap<String, LoggedSignal>,
    logged_signal_acks: &HashSet<String>,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    let signals_root = index::signals_root(context_root);
    let mut acknowledgments_by_id = BTreeMap::new();
    let mut signals_by_id = BTreeMap::new();

    for agent in state.agents.values() {
        for signal_session_id in
            signal_session_keys(&state.session_id, agent.agent_session_id.as_deref())
        {
            let signal_dir = signals_root.join(&agent.runtime).join(signal_session_id);
            for acknowledgment in read_acknowledgments(&signal_dir)? {
                acknowledgments_by_id
                    .entry(acknowledgment.signal_id.clone())
                    .or_insert((agent.runtime.clone(), acknowledgment));
            }
            for signal in read_acknowledged_signals(&signal_dir)? {
                signals_by_id
                    .entry(signal.signal_id.clone())
                    .or_insert(signal);
            }
        }
    }

    for (signal_id, (runtime, acknowledgment)) in acknowledgments_by_id {
        if logged_signal_acks.contains(&signal_id) {
            continue;
        }
        let signal = signals_by_id.get(&signal_id);
        let logged_signal = sent_signals.get(&signal_id);
        entries.push(signal_ack_entry(
            &state.session_id,
            &runtime,
            logged_signal,
            signal,
            &acknowledgment,
            payload_scope,
        )?);
    }

    Ok(entries)
}

fn signal_ack_entry(
    session_id: &str,
    runtime: &str,
    logged_signal: Option<&LoggedSignal>,
    signal: Option<&Signal>,
    acknowledgment: &SignalAck,
    payload_scope: TimelinePayloadScope,
) -> Result<TimelineEntry, CliError> {
    let payload = timeline_payload(
        &serde_json::json!({
            "logged_signal": logged_signal,
            "signal": signal,
            "acknowledgment": acknowledgment,
        }),
        "signal acknowledgment",
        payload_scope,
    )?;
    let agent_id = logged_signal.map_or(runtime, |logged_signal| logged_signal.agent_id.as_str());
    let command = signal
        .map(|signal| signal.command.as_str())
        .or_else(|| logged_signal.map(|logged_signal| logged_signal.command.as_str()));
    let summary = signal_ack_summary(
        &acknowledgment.signal_id,
        agent_id,
        acknowledgment.result,
        command,
    );

    Ok(TimelineEntry {
        entry_id: format!("signal-ack-{}", acknowledgment.signal_id),
        recorded_at: acknowledgment.acknowledged_at.clone(),
        kind: "signal_acknowledged".into(),
        session_id: session_id.to_string(),
        agent_id: Some(agent_id.to_string()),
        task_id: None,
        summary,
        payload,
    })
}
