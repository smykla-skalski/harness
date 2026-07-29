use std::collections::BTreeSet;

use serde::Serialize;
use tokio::sync::broadcast;

use crate::daemon::protocol::StreamEvent;
use crate::workspace::utc_now;

#[derive(Serialize)]
pub(super) struct AcpBridgeResyncIncidentPayload {
    pub(super) kind: String,
    pub(super) bridge_epoch: String,
    pub(super) continuity: u64,
    pub(super) next_seq: u64,
    pub(super) truncated: bool,
    pub(super) affected_logical_session_ids: Vec<String>,
}

#[derive(Serialize)]
pub(super) struct AcpPoolKeyMismatchIncidentPayload {
    pub(super) kind: String,
    pub(super) observed_process_keys: Vec<String>,
    pub(super) affected_logical_session_ids: Vec<String>,
}

pub(super) fn replay_safe_resync_events(events: Vec<StreamEvent>) -> Vec<StreamEvent> {
    events
        .into_iter()
        .filter(|event| {
            event.event == "acp_events"
                || event.event == "acp_bridge_resync_incident"
                || event.event == "acp_process_incident"
        })
        .collect()
}

pub(super) fn dedupe_incident_replays(events: Vec<StreamEvent>) -> Vec<StreamEvent> {
    let mut seen = BTreeSet::<String>::new();
    let mut deduped = Vec::with_capacity(events.len());
    for event in events {
        if event.event != "acp_process_incident" && event.event != "acp_bridge_resync_incident" {
            deduped.push(event);
            continue;
        }
        let key = format!(
            "{}|{}|{}",
            event.event,
            event.session_id.as_deref().unwrap_or(""),
            event.payload
        );
        if seen.insert(key) {
            deduped.push(event);
        }
    }
    deduped
}

pub(super) fn incident_key(
    payload: &AcpBridgeResyncIncidentPayload,
) -> (String, u64, u64, bool, Vec<String>) {
    (
        payload.bridge_epoch.clone(),
        payload.continuity,
        payload.next_seq,
        payload.truncated,
        payload.affected_logical_session_ids.clone(),
    )
}

pub(super) fn bridge_resync_incident_payload(
    bridge_epoch: String,
    continuity: u64,
    next_seq: u64,
    truncated: bool,
    affected_logical_session_ids: Vec<String>,
) -> AcpBridgeResyncIncidentPayload {
    AcpBridgeResyncIncidentPayload {
        kind: "protocol_desync".to_string(),
        bridge_epoch,
        continuity,
        next_seq,
        truncated,
        affected_logical_session_ids,
    }
}

pub(super) fn emit_bridge_resync_incident(
    sender: &broadcast::Sender<StreamEvent>,
    payload: &AcpBridgeResyncIncidentPayload,
) {
    if let Some(events) = bridge_resync_incident_events(payload) {
        for event in events {
            let _ = sender.send(event);
        }
    }
}

pub(super) fn emit_pool_key_mismatch_incidents(
    sender: &broadcast::Sender<StreamEvent>,
    payload: &AcpPoolKeyMismatchIncidentPayload,
) {
    if let Some(events) = pool_key_mismatch_incident_events(payload) {
        for event in events {
            let _ = sender.send(event);
        }
    }
}

pub(super) fn pool_key_mismatch_incident_events(
    payload: &AcpPoolKeyMismatchIncidentPayload,
) -> Option<Vec<StreamEvent>> {
    let serialized_payload = serde_json::to_value(payload).ok()?;
    if payload.affected_logical_session_ids.is_empty() {
        return Some(vec![StreamEvent {
            event: "acp_process_incident".to_string(),
            recorded_at: utc_now(),
            session_id: None,
            payload: serialized_payload,
        }]);
    }
    Some(
        payload
            .affected_logical_session_ids
            .iter()
            .map(|session_id| StreamEvent {
                event: "acp_process_incident".to_string(),
                recorded_at: utc_now(),
                session_id: Some(session_id.clone()),
                payload: serialized_payload.clone(),
            })
            .collect(),
    )
}

pub(super) fn bridge_resync_incident_events(
    payload: &AcpBridgeResyncIncidentPayload,
) -> Option<Vec<StreamEvent>> {
    let serialized_payload = serde_json::to_value(payload).ok()?;
    if payload.affected_logical_session_ids.is_empty() {
        return Some(vec![StreamEvent {
            event: "acp_bridge_resync_incident".to_string(),
            recorded_at: utc_now(),
            session_id: None,
            payload: serialized_payload,
        }]);
    }
    let mut events = Vec::with_capacity(payload.affected_logical_session_ids.len());
    for session_id in &payload.affected_logical_session_ids {
        events.push(StreamEvent {
            event: "acp_bridge_resync_incident".to_string(),
            recorded_at: utc_now(),
            session_id: Some(session_id.clone()),
            payload: serialized_payload.clone(),
        });
    }
    Some(events)
}
