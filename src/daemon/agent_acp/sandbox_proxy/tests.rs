use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, OnceLock};

use super::incidents::{
    AcpBridgeResyncIncidentPayload, bridge_resync_incident_events,
    pool_key_mismatch_incident_events,
};
use super::*;
use crate::agents::kind::DisconnectReason;
use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentManagerHandle,
    AcpAgentReconcileResponse,
};
use crate::daemon::protocol::StreamEvent;
use crate::errors::CliErrorKind;
use crate::session::types::AgentStatus;

#[test]
fn replay_safe_resync_events_keeps_safe_events_only() {
    let events = vec![
        stream_event("acp_agent_started"),
        stream_event("acp_events"),
        stream_event("acp_permission_requested"),
        stream_event("acp_events"),
    ];

    let filtered = replay_safe_resync_events(events);

    assert_eq!(
        filtered
            .iter()
            .map(|event| event.event.as_str())
            .collect::<Vec<_>>(),
        vec!["acp_events", "acp_events"]
    );
}

#[test]
fn replay_safe_resync_events_keeps_resync_incidents() {
    let events = vec![
        stream_event("acp_bridge_resync_incident"),
        stream_event("acp_agent_started"),
    ];
    let filtered = replay_safe_resync_events(events);
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].event, "acp_bridge_resync_incident");
}

#[test]
fn replay_safe_resync_events_keeps_process_incidents() {
    let events = vec![
        stream_event("acp_process_incident"),
        stream_event("acp_agent_started"),
    ];
    let filtered = replay_safe_resync_events(events);
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].event, "acp_process_incident");
}

#[test]
fn dedupe_incident_replays_drops_identical_process_incidents() {
    let repeated = StreamEvent {
        event: "acp_process_incident".to_string(),
        recorded_at: "2026-04-29T00:00:00Z".to_string(),
        session_id: Some("sess-1".to_string()),
        payload: serde_json::json!({
            "kind": "process_exit",
            "process_key": "pk",
        }),
    };
    let filtered =
        dedupe_incident_replays(vec![repeated.clone(), repeated, stream_event("acp_events")]);
    assert_eq!(filtered.len(), 2);
    assert_eq!(filtered[0].event, "acp_process_incident");
    assert_eq!(filtered[1].event, "acp_events");
}

#[test]
fn dedupe_incident_replays_drops_identical_resync_incidents() {
    let repeated = StreamEvent {
        event: "acp_bridge_resync_incident".to_string(),
        recorded_at: "2026-04-29T00:00:00Z".to_string(),
        session_id: Some("sess-1".to_string()),
        payload: serde_json::json!({
            "kind": "protocol_desync",
            "bridge_epoch": "epoch-1",
            "continuity": 3,
        }),
    };
    let filtered =
        dedupe_incident_replays(vec![repeated.clone(), repeated, stream_event("acp_events")]);
    assert_eq!(filtered.len(), 2);
    assert_eq!(filtered[0].event, "acp_bridge_resync_incident");
    assert_eq!(filtered[1].event, "acp_events");
}

fn stream_event(event: &str) -> StreamEvent {
    StreamEvent {
        event: event.to_string(),
        recorded_at: "2026-04-29T00:00:00Z".to_string(),
        session_id: Some("sess-1".to_string()),
        payload: serde_json::json!({}),
    }
}

#[test]
fn bridge_resync_incident_event_uses_expected_kind_and_scope() {
    let event = bridge_resync_incident_event(&AcpBridgeResyncIncidentPayload {
        kind: "protocol_desync".to_string(),
        bridge_epoch: "epoch-1".to_string(),
        continuity: 7,
        next_seq: 11,
        truncated: true,
        affected_logical_session_ids: vec!["sess-1".to_string()],
    })
    .expect("incident event");

    assert_eq!(event.event, "acp_bridge_resync_incident");
    assert_eq!(event.session_id, None);
    assert_eq!(event.payload["kind"], "protocol_desync");
    assert_eq!(
        event.payload["affected_logical_session_ids"],
        serde_json::json!(["sess-1"])
    );
}

#[test]
fn bridge_resync_incident_events_fan_out_by_session() {
    let payload = AcpBridgeResyncIncidentPayload {
        kind: "protocol_desync".to_string(),
        bridge_epoch: "epoch-1".to_string(),
        continuity: 7,
        next_seq: 11,
        truncated: false,
        affected_logical_session_ids: vec!["sess-a".to_string(), "sess-b".to_string()],
    };
    let events = bridge_resync_incident_events(&payload).expect("events");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].session_id.as_deref(), Some("sess-a"));
    assert_eq!(events[1].session_id.as_deref(), Some("sess-b"));
}

#[test]
fn incident_key_tracks_epoch_continuity_and_cursor_shape() {
    let payload = AcpBridgeResyncIncidentPayload {
        kind: "protocol_desync".to_string(),
        bridge_epoch: "epoch-5".to_string(),
        continuity: 42,
        next_seq: 77,
        truncated: false,
        affected_logical_session_ids: vec![],
    };
    assert_eq!(
        incident_key(&payload),
        ("epoch-5".to_string(), 42, 77, false, Vec::<String>::new())
    );
}

#[test]
fn reconcile_sessions_uses_known_and_inspect_sets() {
    let mut known = BTreeSet::new();
    known.insert("sess-old".to_string());
    let inspect = AcpAgentInspectResponse {
        agents: vec![AcpAgentInspectSnapshot {
            acp_id: "a1".to_string(),
            session_id: "sess-new".to_string(),
            agent_id: "fake".to_string(),
            display_name: "Fake".to_string(),
            pid: 1,
            pgid: 1,
            process_key: "pk".to_string(),
            uptime_ms: 1,
            last_update_at: "2026-01-01T00:00:00Z".to_string(),
            last_client_call_at: None,
            watchdog_state: "active".to_string(),
            permission_mode: "daemon_bridge".to_string(),
            permission_log_path: None,
            pending_permissions: 0,
            permission_queue_depth: 0,
            terminal_count: 0,
            prompt_deadline_remaining_ms: 0,
        }],
        available: true,
        issue_message: None,
    };
    let merged = reconcile_sessions(known, &inspect);
    assert_eq!(merged, vec!["sess-new".to_string(), "sess-old".to_string()]);
}

#[test]
fn distinct_process_keys_for_session_dedupes_and_sorts_keys() {
    let inspect = AcpAgentInspectResponse {
        agents: vec![
            inspect_snapshot("sess-1", "pk-b"),
            inspect_snapshot("sess-1", "pk-a"),
            inspect_snapshot("sess-1", "pk-a"),
            inspect_snapshot("sess-2", "pk-z"),
        ],
        available: true,
        issue_message: None,
    };
    assert_eq!(
        distinct_process_keys_for_session(&inspect, "sess-1"),
        vec!["pk-a".to_string(), "pk-b".to_string()]
    );
}

#[test]
fn count_live_bridge_snapshots_uses_agent_status_not_watchdog_state() {
    let mut idle_inspect = inspect_snapshot("sess-1", "pk-idle");
    idle_inspect.acp_id = "acp-idle".to_string();
    idle_inspect.watchdog_state = "paused".to_string();
    let mut disconnected_inspect = inspect_snapshot("sess-1", "pk-disconnected");
    disconnected_inspect.acp_id = "acp-disconnected".to_string();
    disconnected_inspect.watchdog_state = "active".to_string();
    let inspect = AcpAgentInspectResponse {
        agents: vec![idle_inspect, disconnected_inspect],
        available: true,
        issue_message: None,
    };

    let live = count_live_bridge_snapshots(inspect, |acp_id| match acp_id {
        "acp-idle" => Ok(acp_snapshot("acp-idle", AgentStatus::Idle)),
        "acp-disconnected" => Ok(acp_snapshot(
            "acp-disconnected",
            AgentStatus::disconnected(DisconnectReason::SessionStopped),
        )),
        unexpected => panic!("unexpected ACP id {unexpected}"),
    })
    .expect("count live bridge snapshots");

    assert_eq!(live, 1);
}

#[test]
fn count_live_bridge_snapshots_fails_closed_on_snapshot_errors() {
    let mut inspect_snapshot = inspect_snapshot("sess-1", "pk-a");
    inspect_snapshot.acp_id = "acp-a".to_string();
    let inspect = AcpAgentInspectResponse {
        agents: vec![inspect_snapshot],
        available: true,
        issue_message: None,
    };
    let error = count_live_bridge_snapshots(inspect, |_| {
        Err(CliErrorKind::workflow_io("snapshot unavailable").into())
    })
    .expect_err("snapshot errors must block force-less disable");

    assert!(error.to_string().contains("snapshot unavailable"));
}

#[test]
fn sandbox_proxy_reconcile_batch_replays_full_snapshot_in_one_pass() {
    let (sender, mut rx) = tokio::sync::broadcast::channel::<StreamEvent>(16);
    let manager = AcpAgentManagerHandle::new(sender, Arc::new(OnceLock::new()));
    manager.set_sandbox_known_sessions(BTreeSet::from([String::from("sess-stale")]));

    manager.apply_sandbox_reconcile(
        AcpAgentReconcileResponse {
            inspect: AcpAgentInspectResponse {
                agents: vec![
                    inspect_snapshot("sess-live", "pk-live"),
                    inspect_snapshot("sess-other", "pk-other"),
                ],
                available: true,
                issue_message: None,
            },
            agents: vec![
                acp_snapshot_for_session("acp-live", "sess-live", "pk-live", AgentStatus::Active),
                acp_snapshot_for_session("acp-other", "sess-other", "pk-other", AgentStatus::Idle),
            ],
        },
        &mut BTreeMap::new(),
    );

    let mut reconciled = BTreeMap::<String, serde_json::Value>::new();
    for _ in 0..4 {
        let Ok(event) = rx.try_recv() else {
            continue;
        };
        if event.event == "acp_agents_reconciled"
            && let Some(session_id) = event.session_id
        {
            reconciled.insert(session_id, event.payload);
        }
    }

    assert_eq!(
        reconciled.keys().cloned().collect::<Vec<_>>(),
        vec![
            "sess-live".to_string(),
            "sess-other".to_string(),
            "sess-stale".to_string(),
        ]
    );
    assert_eq!(
        reconciled["sess-live"]["agents"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        reconciled["sess-live"]["inspect"]["agents"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        reconciled["sess-stale"]["agents"].as_array().map(Vec::len),
        Some(0)
    );
    assert_eq!(
        reconciled["sess-stale"]["inspect"]["agents"]
            .as_array()
            .map(Vec::len),
        Some(0)
    );
    assert_eq!(
        manager.sandbox_known_sessions(),
        BTreeSet::from([String::from("sess-live"), String::from("sess-other")])
    );
}

#[test]
fn pool_key_mismatch_incident_events_fan_out_by_session() {
    let payload = AcpPoolKeyMismatchIncidentPayload {
        kind: "pool_key_mismatch".to_string(),
        observed_process_keys: vec!["pk-a".to_string(), "pk-b".to_string()],
        affected_logical_session_ids: vec!["sess-1".to_string(), "sess-2".to_string()],
    };
    let events = pool_key_mismatch_incident_events(&payload).expect("events");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].event, "acp_process_incident");
    assert_eq!(events[0].session_id.as_deref(), Some("sess-1"));
    assert_eq!(events[1].session_id.as_deref(), Some("sess-2"));
    assert_eq!(events[0].payload["kind"], "pool_key_mismatch");
}

#[test]
fn pool_key_mismatch_dedupe_emits_only_on_change() {
    let (sender, mut rx) = tokio::sync::broadcast::channel::<StreamEvent>(16);
    let mut seen = BTreeMap::<String, Vec<String>>::new();
    let session_id = "sess-1".to_string();
    let process_keys = vec!["pk-a".to_string(), "pk-b".to_string()];

    let changed = seen.get(&session_id) != Some(&process_keys);
    seen.insert(session_id.clone(), process_keys.clone());
    if changed {
        emit_pool_key_mismatch_incidents(
            &sender,
            &AcpPoolKeyMismatchIncidentPayload {
                kind: "pool_key_mismatch".to_string(),
                observed_process_keys: process_keys.clone(),
                affected_logical_session_ids: vec![session_id.clone()],
            },
        );
    }
    let changed = seen.get(&session_id) != Some(&process_keys);
    seen.insert(session_id.clone(), process_keys.clone());
    if changed {
        emit_pool_key_mismatch_incidents(
            &sender,
            &AcpPoolKeyMismatchIncidentPayload {
                kind: "pool_key_mismatch".to_string(),
                observed_process_keys: process_keys,
                affected_logical_session_ids: vec![session_id],
            },
        );
    }

    let first = rx.try_recv().expect("first incident");
    assert_eq!(first.event, "acp_process_incident");
    assert!(
        rx.try_recv().is_err(),
        "second identical incident must be deduped"
    );
}

#[test]
fn pool_key_mismatch_state_is_cleared_for_non_mismatch_keys() {
    let (sender, mut rx) = tokio::sync::broadcast::channel::<StreamEvent>(16);
    let mut seen = BTreeMap::<String, Vec<String>>::new();
    let session_id = "sess-1";

    maybe_emit_pool_key_mismatch_incident(
        &sender,
        &mut seen,
        session_id,
        vec!["pk-a".to_string(), "pk-b".to_string()],
    );
    let _ = rx.try_recv().expect("mismatch incident");
    assert!(seen.contains_key(session_id));

    maybe_emit_pool_key_mismatch_incident(&sender, &mut seen, session_id, vec!["pk-a".to_string()]);
    assert!(!seen.contains_key(session_id));
    assert!(rx.try_recv().is_err(), "no extra incident expected");
}

fn inspect_snapshot(session_id: &str, process_key: &str) -> AcpAgentInspectSnapshot {
    AcpAgentInspectSnapshot {
        acp_id: format!("{session_id}-{process_key}"),
        session_id: session_id.to_string(),
        agent_id: "fake".to_string(),
        display_name: "Fake".to_string(),
        pid: 1,
        pgid: 1,
        process_key: process_key.to_string(),
        uptime_ms: 1,
        last_update_at: "2026-01-01T00:00:00Z".to_string(),
        last_client_call_at: None,
        watchdog_state: "active".to_string(),
        permission_mode: "daemon_bridge".to_string(),
        permission_log_path: None,
        pending_permissions: 0,
        permission_queue_depth: 0,
        terminal_count: 0,
        prompt_deadline_remaining_ms: 0,
    }
}

fn acp_snapshot(acp_id: &str, status: AgentStatus) -> AcpAgentSnapshot {
    acp_snapshot_for_session(acp_id, "sess-1", "pk", status)
}

fn acp_snapshot_for_session(
    acp_id: &str,
    session_id: &str,
    process_key: &str,
    status: AgentStatus,
) -> AcpAgentSnapshot {
    AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: "fake".to_string(),
        display_name: "Fake ACP".to_string(),
        status,
        pid: 1,
        pgid: 1,
        project_dir: "/tmp/project".to_string(),
        process_key: process_key.to_string(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: "daemon_bridge".to_string(),
        permission_log_path: None,
        terminal_count: 0,
        created_at: "2026-01-01T00:00:00Z".to_string(),
        updated_at: "2026-01-01T00:00:00Z".to_string(),
    }
}

#[test]
fn bridge_resync_incident_payload_uses_protocol_desync_kind() {
    let payload = bridge_resync_incident_payload(
        "epoch-1".to_string(),
        9,
        12,
        true,
        vec!["sess-1".to_string()],
    );
    assert_eq!(payload.kind, "protocol_desync");
    assert_eq!(payload.bridge_epoch, "epoch-1");
    assert_eq!(payload.continuity, 9);
}

fn bridge_resync_incident_event(payload: &AcpBridgeResyncIncidentPayload) -> Option<StreamEvent> {
    Some(StreamEvent {
        event: "acp_bridge_resync_incident".to_string(),
        recorded_at: utc_now(),
        session_id: None,
        payload: serde_json::to_value(payload).ok()?,
    })
}
