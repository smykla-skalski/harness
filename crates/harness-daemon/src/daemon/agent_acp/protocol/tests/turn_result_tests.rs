use agent_client_protocol::schema::v1::{
    ContentBlock, ContentChunk, PromptResponse, SessionId, SessionNotification, SessionUpdate,
    StopReason, TextContent,
};

use super::super::session_guard::RouteTarget;
use super::*;

async fn route_update(
    guard: &SessionRouteGuard,
    supervisor: &AcpSessionSupervisor,
    manager: &AcpAgentManagerHandle,
    notifications: &mpsc::Sender<RoutedSessionNotification>,
    session_id: &SessionId,
    update: SessionUpdate,
) {
    route_session_notification(
        guard,
        supervisor,
        manager,
        notifications,
        SessionNotification::new(session_id.clone(), update),
    )
    .await
    .expect("route update");
}

fn text_update(text: &str) -> SessionUpdate {
    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
        text,
    ))))
}

fn route_target(session_id: &str) -> RouteTarget {
    RouteTarget {
        acp_id: format!("agent-{session_id}"),
        session_id: session_id.to_owned(),
    }
}

#[tokio::test]
#[cfg(unix)]
async fn terminal_result_joins_text_and_keeps_diagnostics_separate() {
    let child = ChildGuard(
        Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn supervisor child"),
    );
    let supervisor = AcpSessionSupervisor::new(&child.0, SupervisionConfig::default());
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-report");
    let harness_session_id = "c6e24bcb-cb15-555b-99fb-9dbb7ccc986e";
    guard.start_session(&session_id, route_target(harness_session_id));
    let manager = protocol_manager("openrouter", "agent-report", harness_session_id);
    let (notification_tx, mut notification_rx) = mpsc::channel(8);

    session_state::begin_turn(&supervisor);
    route_update(
        &guard,
        &supervisor,
        &manager,
        &notification_tx,
        &session_id,
        text_update("first "),
    )
    .await;
    route_update(
        &guard,
        &supervisor,
        &manager,
        &notification_tx,
        &session_id,
        SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
            "diagnostic",
        )))),
    )
    .await;
    route_update(
        &guard,
        &supervisor,
        &manager,
        &notification_tx,
        &session_id,
        text_update("second"),
    )
    .await;
    session_state::record_stop_reason(&supervisor, &PromptResponse::new(StopReason::EndTurn));

    let state = supervisor.session_state().expect("session state");
    let result = state.last_turn_result.expect("terminal turn result");
    assert_eq!(result.report, "first second");
    assert_eq!(result.stop_reason, "end_turn");

    let forwarded = std::iter::from_fn(|| notification_rx.try_recv().ok()).collect::<Vec<_>>();
    assert_eq!(forwarded.len(), 3);
    assert!(matches!(
        forwarded[1].notification.update,
        SessionUpdate::AgentThoughtChunk(_)
    ));
}

#[tokio::test]
#[cfg(unix)]
async fn discarded_turn_does_not_publish_partial_or_stale_result() {
    let child = ChildGuard(
        Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn supervisor child"),
    );
    let supervisor = AcpSessionSupervisor::new(&child.0, SupervisionConfig::default());

    session_state::begin_turn(&supervisor);
    session_state::apply_live_turn_update(&supervisor, &text_update("complete"));
    session_state::record_stop_reason(&supervisor, &PromptResponse::new(StopReason::EndTurn));
    assert!(
        supervisor
            .session_state()
            .and_then(|state| state.last_turn_result)
            .is_some()
    );

    session_state::begin_turn(&supervisor);
    session_state::apply_live_turn_update(&supervisor, &text_update("partial"));
    session_state::discard_turn(&supervisor);

    assert!(
        supervisor
            .session_state()
            .and_then(|state| state.last_turn_result)
            .is_none()
    );
}
