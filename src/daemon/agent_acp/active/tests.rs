use super::*;
use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::session::types::{
    AgentRegistration, AgentStatus as SessionAgentStatus, SessionMetrics, SessionRole,
    SessionState, SessionStatus,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use tokio::sync::{broadcast, mpsc};

#[test]
fn process_incident_event_maps_process_exit() {
    let snapshot = disconnected_snapshot(DisconnectReason::ProcessExited {
        code: Some(7),
        signal: None,
    });
    let Some(event) = process_incident_event(&snapshot) else {
        unreachable!("incident event");
    };
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
    let Some(event) = process_incident_event(&snapshot) else {
        unreachable!("incident event");
    };
    assert_eq!(event.payload["kind"], "transport_closed");
    assert_eq!(event.payload["reason_kind"], "transport_closed");
    assert_eq!(event.payload["restart_applied"], false);
    assert_eq!(event.payload["backoff_applied"], false);
    assert_eq!(event.payload["quarantine_applied"], false);
}

#[test]
fn process_incident_event_maps_stdio_closed_to_transport_kind() {
    let snapshot = disconnected_snapshot(DisconnectReason::StdioClosed);
    let Some(event) = process_incident_event(&snapshot) else {
        unreachable!("incident event");
    };
    assert_eq!(event.payload["kind"], "transport_closed");
    assert_eq!(event.payload["reason_kind"], "stdio_closed");
}

#[test]
fn process_incident_event_maps_prompt_timeout_to_protocol_desync() {
    let snapshot = disconnected_snapshot(DisconnectReason::PromptTimeout);
    let Some(event) = process_incident_event(&snapshot) else {
        unreachable!("incident event");
    };
    assert_eq!(event.payload["kind"], "protocol_desync");
    assert_eq!(event.payload["reason_kind"], "prompt_timeout");
    assert_eq!(event.payload["restart_applied"], false);
    assert_eq!(event.payload["backoff_applied"], false);
    assert_eq!(event.payload["quarantine_applied"], false);
}

#[test]
fn shared_stderr_tail_redacts_known_secret_patterns() {
    let tail = SharedStderrTail::default();
    tail.append(b"Authorization: Bearer supersecret-token\n");
    tail.append(b"ADMIN_TOKEN=topsecret-value\n");

    let rendered = tail.as_string().expect("stderr tail");

    assert!(rendered.contains("[REDACTED:BEARER]"));
    assert!(rendered.contains("[REDACTED:ENV_SECRET]"));
    assert!(!rendered.contains("supersecret-token"));
    assert!(!rendered.contains("topsecret-value"));
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

#[tokio::test(flavor = "multi_thread")]
async fn spawn_event_forwarder_persists_live_acp_batches_to_db() {
    let (sender, mut receiver) = broadcast::channel(8);
    let (tx, rx) = mpsc::channel(1);
    let db = Arc::new(Mutex::new(DaemonDb::open_in_memory().expect("open db")));
    {
        let db = db.lock().expect("db lock");
        db.sync_project(&sample_project()).expect("sync project");
        db.sync_session(&sample_project().project_id, &sample_session_state())
            .expect("sync session");
    }

    let task = spawn_event_forwarder(
        sender,
        rx,
        Some(LiveEventPersistence::new(
            Arc::clone(&db),
            "sess-1",
            "gemini-worker",
            "gemini",
        )),
    );
    tx.send(EventBatch {
        acp_id: "acp-1".into(),
        session_id: "sess-1".into(),
        raw_count: 1,
        events: vec![ConversationEvent {
            timestamp: Some("2026-04-29T00:00:01Z".into()),
            sequence: 1,
            kind: ConversationEventKind::AssistantText {
                content: "hello from Gemini".into(),
            },
            agent: "ignored".into(),
            session_id: "ignored".into(),
        }],
    })
    .await
    .expect("send event batch");
    drop(tx);

    let event = receiver.recv().await.expect("receive broadcast event");
    assert_eq!(event.event, "acp_events");
    task.await.expect("join event forwarder");

    let db = db.lock().expect("db lock");
    let events = db
        .load_conversation_events("sess-1", "gemini-worker")
        .expect("load persisted conversation events");
    assert_eq!(events.len(), 1);
    let ConversationEventKind::AssistantText { content } = &events[0].kind else {
        panic!("expected assistant text event");
    };
    assert_eq!(content, "hello from Gemini");
}

fn sample_project() -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-abc123".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-abc123".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/project-abc123".into(),
        is_worktree: false,
        worktree_name: None,
    }
}

fn sample_session_state() -> SessionState {
    let mut agents = BTreeMap::new();
    agents.insert(
        "gemini-worker".into(),
        AgentRegistration {
            agent_id: "gemini-worker".into(),
            name: "Gemini Worker".into(),
            runtime: "gemini".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-29T00:00:00Z".into(),
            updated_at: "2026-04-29T00:00:00Z".into(),
            status: SessionAgentStatus::Active,
            agent_session_id: Some("gemini-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-29T00:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    SessionState {
        schema_version: crate::session::types::CURRENT_VERSION,
        state_version: 1,
        session_id: "sess-1".into(),
        project_name: String::new(),
        worktree_path: std::path::PathBuf::new(),
        shared_path: std::path::PathBuf::new(),
        origin_path: std::path::PathBuf::new(),
        branch_ref: String::new(),
        title: "sess-1".into(),
        context: "active ACP test session".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-04-29T00:00:00Z".into(),
        updated_at: "2026-04-29T00:00:00Z".into(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some("2026-04-29T00:00:00Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}
