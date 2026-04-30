use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::service::protocol::{StreamEvent, WsAcpInspect};
use crate::daemon::service::{broadcast, tokio_watch, utc_now};
use std::collections::BTreeSet;
use tokio::task::JoinHandle;

pub(super) fn spawn_acp_inspect_publisher(
    sender: broadcast::Sender<StreamEvent>,
    shutdown_rx: tokio_watch::Receiver<bool>,
    acp_agent_manager: AcpAgentManagerHandle,
) -> JoinHandle<()> {
    tokio::spawn(run_acp_inspect_publisher(
        sender,
        shutdown_rx,
        acp_agent_manager,
    ))
}

async fn run_acp_inspect_publisher(
    sender: broadcast::Sender<StreamEvent>,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
    acp_agent_manager: AcpAgentManagerHandle,
) {
    let mut event_rx = sender.subscribe();
    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
            received = event_rx.recv() => {
                if handle_publisher_receive(&sender, &acp_agent_manager, received) {
                    break;
                }
            }
        }
    }
}

fn acp_inspect_trigger_session_id(event: &StreamEvent) -> Option<&str> {
    // This list is the ACP -> inspect refresh protocol. Any new ACP event that
    // mutates runtime-visible state must be added here so live inspect snapshots
    // stay fresh for the UI.
    match event.event.as_str() {
        "acp_agent_started"
        | "acp_agent_updated"
        | "acp_agent_stopped"
        | "acp_agent_failed"
        | "acp_agent_disconnected"
        | "acp_agents_reconciled"
        | "acp_events"
        | "acp_process_incident"
        | "acp_bridge_resync_incident"
        | "acp_permission_requested"
        | "acp_permission_resolved"
        | "acp_permission_shutdown"
        | "acp_permission_timeout"
        | "acp_permission_batch_resolved" => event.session_id.as_deref(),
        _ => None,
    }
}

fn publish_catchup_acp_inspect_events(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
) {
    for session_id in catchup_session_ids(acp_agent_manager) {
        publish_acp_inspect_event(sender, acp_agent_manager, &session_id);
    }
}

fn catchup_session_ids(acp_agent_manager: &AcpAgentManagerHandle) -> BTreeSet<String> {
    acp_agent_manager
        .inspect(None)
        .agents
        .into_iter()
        .map(|agent| agent.session_id)
        .collect()
}

fn handle_publisher_receive(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
    received: Result<StreamEvent, broadcast::error::RecvError>,
) -> bool {
    match received {
        Ok(event) => {
            if let Some(session_id) = acp_inspect_trigger_session_id(&event) {
                publish_acp_inspect_event(sender, acp_agent_manager, session_id);
            }
            false
        }
        Err(broadcast::error::RecvError::Lagged(_)) => {
            publish_catchup_acp_inspect_events(sender, acp_agent_manager);
            false
        }
        Err(broadcast::error::RecvError::Closed) => true,
    }
}

fn publish_acp_inspect_event(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
    session_id: &str,
) {
    let Some(payload) = inspect_payload(acp_agent_manager, session_id) else {
        return;
    };
    let _ = sender.send(StreamEvent {
        event: "acp_inspect".to_string(),
        recorded_at: utc_now(),
        session_id: Some(session_id.to_string()),
        payload,
    });
}

fn inspect_payload(
    acp_agent_manager: &AcpAgentManagerHandle,
    session_id: &str,
) -> Option<serde_json::Value> {
    let payload = serde_json::to_value(WsAcpInspect {
        inspect: acp_agent_manager.inspect(Some(session_id)),
    });
    if let Err(error) = &payload {
        log_inspect_payload_error(session_id, error);
    }
    payload.ok()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_inspect_payload_error(session_id: &str, error: &serde_json::Error) {
    tracing::warn!(
        %error,
        session_id,
        "failed to serialize ACP inspect push payload"
    );
}

#[cfg(test)]
mod tests {
    use super::acp_inspect_trigger_session_id;
    use crate::daemon::agent_acp::{AcpAgentInspectResponse, AcpAgentInspectSnapshot};
    use crate::daemon::protocol::StreamEvent;
    use serde_json::json;

    fn stream_event(event: &str, session_id: Option<&str>) -> StreamEvent {
        StreamEvent {
            event: event.to_string(),
            recorded_at: "2026-04-29T00:00:00Z".to_string(),
            session_id: session_id.map(str::to_string),
            payload: json!({}),
        }
    }

    #[test]
    fn acp_inspect_trigger_uses_session_scoped_acp_events() {
        let event = stream_event("acp_events", Some("sess-1"));
        assert_eq!(acp_inspect_trigger_session_id(&event), Some("sess-1"));
    }

    #[test]
    fn acp_inspect_trigger_ignores_non_acp_or_self_push_events() {
        assert_eq!(
            acp_inspect_trigger_session_id(&stream_event("session_updated", Some("sess-1"))),
            None
        );
        assert_eq!(
            acp_inspect_trigger_session_id(&stream_event("acp_inspect", Some("sess-1"))),
            None
        );
        assert_eq!(
            acp_inspect_trigger_session_id(&stream_event("acp_events", None)),
            None
        );
    }

    #[test]
    fn catchup_session_ids_deduplicate_sessions() {
        let response = AcpAgentInspectResponse {
            agents: vec![
                inspect_snapshot("sess-1", "acp-1", "agent-1"),
                inspect_snapshot("sess-1", "acp-2", "agent-2"),
                inspect_snapshot("sess-2", "acp-3", "agent-3"),
            ],
        };

        let sessions = response
            .agents
            .into_iter()
            .map(|agent| agent.session_id)
            .collect::<std::collections::BTreeSet<_>>();

        assert_eq!(
            sessions,
            std::collections::BTreeSet::from(["sess-1".to_string(), "sess-2".to_string(),])
        );
    }

    fn inspect_snapshot(session_id: &str, acp_id: &str, agent_id: &str) -> AcpAgentInspectSnapshot {
        AcpAgentInspectSnapshot {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
            agent_id: agent_id.to_string(),
            display_name: agent_id.to_string(),
            pid: 1,
            pgid: 1,
            process_key: String::new(),
            uptime_ms: 1,
            last_update_at: "2026-04-29T00:00:00Z".to_string(),
            last_client_call_at: None,
            watchdog_state: "active".to_string(),
            permission_mode: String::new(),
            permission_log_path: None,
            pending_permissions: 0,
            permission_queue_depth: 0,
            terminal_count: 0,
            prompt_deadline_remaining_ms: 0,
        }
    }
}
