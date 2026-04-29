use super::*;

#[test]
fn process_incident_event_maps_process_exit() {
    let snapshot = disconnected_snapshot(DisconnectReason::ProcessExited {
        code: Some(7),
        signal: None,
    });
    let event = process_incident_event(&snapshot).expect("incident event");
    assert_eq!(event.event, "acp_process_incident");
    assert_eq!(event.payload["kind"], "process_exit");
    assert_eq!(event.payload["reason_kind"], "process_exited");
    assert_eq!(event.payload["exit_code"], 7);
    assert_eq!(event.payload["restart_applied"], false);
    assert_eq!(event.payload["backoff_applied"], false);
    assert_eq!(event.payload["quarantine_applied"], false);
    assert_eq!(
        event.payload["affected_logical_session_ids"],
        serde_json::json!(["sess-1"])
    );
}

#[test]
fn process_incident_event_skips_session_stopped() {
    let snapshot = disconnected_snapshot(DisconnectReason::SessionStopped);
    assert!(process_incident_event(&snapshot).is_none());
}

#[test]
fn process_incident_event_maps_transport_closed() {
    let snapshot = disconnected_snapshot(DisconnectReason::TransportClosed);
    let event = process_incident_event(&snapshot).expect("incident event");
    assert_eq!(event.payload["kind"], "transport_closed");
    assert_eq!(event.payload["reason_kind"], "transport_closed");
    assert_eq!(event.payload["restart_applied"], false);
    assert_eq!(event.payload["backoff_applied"], false);
    assert_eq!(event.payload["quarantine_applied"], false);
}

#[test]
fn process_incident_event_maps_prompt_timeout_to_protocol_desync() {
    let snapshot = disconnected_snapshot(DisconnectReason::PromptTimeout);
    let event = process_incident_event(&snapshot).expect("incident event");
    assert_eq!(event.payload["kind"], "protocol_desync");
    assert_eq!(event.payload["reason_kind"], "prompt_timeout");
    assert_eq!(event.payload["restart_applied"], false);
    assert_eq!(event.payload["backoff_applied"], false);
    assert_eq!(event.payload["quarantine_applied"], false);
}

#[test]
fn sorted_singleton_returns_one_stable_session_id() {
    assert_eq!(sorted_singleton("sess-2".to_string()), vec!["sess-2"]);
}

#[test]
fn reason_kind_uses_raw_unknown_tag_when_present() {
    assert_eq!(
        reason_kind(&DisconnectReason::Unknown {
            raw_kind: Some("custom_future_reason".to_string()),
        }),
        "custom_future_reason"
    );
}

fn disconnected_snapshot(reason: DisconnectReason) -> AcpAgentSnapshot {
    AcpAgentSnapshot {
        acp_id: "acp-1".to_string(),
        session_id: "sess-1".to_string(),
        agent_id: "fake".to_string(),
        display_name: "Fake ACP".to_string(),
        status: AgentStatus::Disconnected {
            reason,
            stderr_tail: Some("boom".to_string()),
        },
        pid: 123,
        pgid: 123,
        project_dir: "/tmp/project".to_string(),
        process_key: "acp-process-key".to_string(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: "daemon_bridge".to_string(),
        permission_log_path: None,
        terminal_count: 0,
        created_at: "2026-04-29T00:00:00Z".to_string(),
        updated_at: "2026-04-29T00:00:00Z".to_string(),
    }
}
