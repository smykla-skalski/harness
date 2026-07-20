use super::acp_inspect_coalesce::{
    ACP_INSPECT_DEBOUNCE, InspectCoalescer, inspect_content_fingerprint,
};
use crate::daemon::agent_acp::{AcpAgentInspectResponse, AcpAgentManagerHandle};
use crate::daemon::service::protocol::{StreamEvent, WsAcpInspect};
use crate::daemon::service::{broadcast, tokio_watch, utc_now};
use crate::errors::CliError;
use std::collections::{BTreeMap, BTreeSet};
use std::future;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep_until};

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
    let mut coalescer = InspectCoalescer::new(ACP_INSPECT_DEBOUNCE);
    let mut last_fingerprints: BTreeMap<String, u64> = BTreeMap::new();
    while publisher_tick(
        &sender,
        &acp_agent_manager,
        &mut shutdown_rx,
        &mut event_rx,
        &mut coalescer,
        &mut last_fingerprints,
    )
    .await
    {}
}

/// Run one publisher event-loop iteration. Returns `false` once the publisher
/// should stop, either because shutdown was signalled or the broadcast channel
/// closed.
async fn publisher_tick(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
    shutdown_rx: &mut tokio_watch::Receiver<bool>,
    event_rx: &mut broadcast::Receiver<StreamEvent>,
    coalescer: &mut InspectCoalescer,
    last_fingerprints: &mut BTreeMap<String, u64>,
) -> bool {
    let flush_at = coalescer.flush_deadline();
    tokio::select! {
        changed = shutdown_rx.changed() => changed.is_ok() && !*shutdown_rx.borrow(),
        received = event_rx.recv() => !handle_publisher_receive(acp_agent_manager, coalescer, received),
        () = sleep_until_deadline(flush_at) => {
            flush_pending_inspects(sender, acp_agent_manager, coalescer, last_fingerprints);
            true
        }
    }
}

async fn sleep_until_deadline(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => sleep_until(deadline).await,
        None => future::pending::<()>().await,
    }
}

fn flush_pending_inspects(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
    coalescer: &mut InspectCoalescer,
    last_fingerprints: &mut BTreeMap<String, u64>,
) {
    for session_id in coalescer.drain() {
        publish_acp_inspect_event(sender, acp_agent_manager, &session_id, last_fingerprints);
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

fn catchup_session_ids(acp_agent_manager: &AcpAgentManagerHandle) -> BTreeSet<String> {
    inspect_response_or_log(
        acp_agent_manager,
        None,
        "failed to inspect ACP sessions during catchup refresh",
    )
    .map_or_else(BTreeSet::new, |response| {
        response
            .agents
            .into_iter()
            .map(|agent| agent.session_id)
            .collect()
    })
}

fn handle_publisher_receive(
    acp_agent_manager: &AcpAgentManagerHandle,
    coalescer: &mut InspectCoalescer,
    received: Result<StreamEvent, broadcast::error::RecvError>,
) -> bool {
    match received {
        Ok(event) => {
            if let Some(session_id) = acp_inspect_trigger_session_id(&event) {
                coalescer.mark(session_id.to_string(), Instant::now());
            }
            false
        }
        Err(broadcast::error::RecvError::Lagged(_)) => {
            let now = Instant::now();
            for session_id in catchup_session_ids(acp_agent_manager) {
                coalescer.mark(session_id, now);
            }
            false
        }
        Err(broadcast::error::RecvError::Closed) => true,
    }
}

fn publish_acp_inspect_event(
    sender: &broadcast::Sender<StreamEvent>,
    acp_agent_manager: &AcpAgentManagerHandle,
    session_id: &str,
    last_fingerprints: &mut BTreeMap<String, u64>,
) {
    let Some(inspect) = inspect_response_or_log(
        acp_agent_manager,
        Some(session_id),
        "failed to build ACP inspect push payload",
    ) else {
        return;
    };
    let fingerprint = inspect_content_fingerprint(&inspect);
    if last_fingerprints.get(session_id) == Some(&fingerprint) {
        return;
    }
    let payload = match serde_json::to_value(WsAcpInspect { inspect }) {
        Ok(payload) => payload,
        Err(error) => {
            log_inspect_payload_error(session_id, &error);
            return;
        }
    };
    last_fingerprints.insert(session_id.to_string(), fingerprint);
    let _ = sender.send(StreamEvent {
        event: "acp_inspect".to_string(),
        recorded_at: utc_now(),
        session_id: Some(session_id.to_string()),
        payload,
    });
}

fn inspect_response_or_log(
    acp_agent_manager: &AcpAgentManagerHandle,
    session_id: Option<&str>,
    message: &str,
) -> Option<AcpAgentInspectResponse> {
    match acp_agent_manager.inspect(session_id) {
        Ok(response) => Some(response),
        Err(error) => {
            log_inspect_response_error(session_id, &error, message);
            None
        }
    }
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

fn log_inspect_response_error(session_id: Option<&str>, error: &CliError, message: &str) {
    session_id.map_or_else(
        || log_global_inspect_response_error(error, message),
        |session_id| log_session_inspect_response_error(session_id, error, message),
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_global_inspect_response_error(error: &CliError, message: &str) {
    tracing::warn!(%error, "{message}");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_session_inspect_response_error(session_id: &str, error: &CliError, message: &str) {
    tracing::warn!(%error, session_id, "{message}");
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
        let event = stream_event("acp_events", Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"));
        assert_eq!(
            acp_inspect_trigger_session_id(&event),
            Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
        );
    }

    #[test]
    fn acp_inspect_trigger_ignores_non_acp_or_self_push_events() {
        assert_eq!(
            acp_inspect_trigger_session_id(&stream_event(
                "session_updated",
                Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
            )),
            None
        );
        assert_eq!(
            acp_inspect_trigger_session_id(&stream_event(
                "acp_inspect",
                Some("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
            )),
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
                inspect_snapshot("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", "acp-1", "agent-1"),
                inspect_snapshot("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc", "acp-2", "agent-2"),
                inspect_snapshot("00b4a39f-719e-5418-abe8-eb3ab6ea614d", "acp-3", "agent-3"),
            ],
            daemon_perceived_now: None,
            available: true,
            issue_message: None,
        };

        let sessions = response
            .agents
            .into_iter()
            .map(|agent| agent.session_id)
            .collect::<std::collections::BTreeSet<_>>();

        assert_eq!(
            sessions,
            std::collections::BTreeSet::from([
                "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".to_string(),
                "00b4a39f-719e-5418-abe8-eb3ab6ea614d".to_string(),
            ])
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
            handshake: None,
            session_state: None,
        }
    }
}
