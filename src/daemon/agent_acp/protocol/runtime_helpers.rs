use crate::agents::acp::supervision::AcpSessionSupervisor;

use agent_client_protocol::schema::v1::SessionNotification;

use super::AcpAgentManagerHandle;
use super::{
    ACP_DEADLINE_EXCEEDED, AcpError, AcpResult, DisconnectReason, ErrorCode,
    RoutedSessionNotification, SessionId, SessionRouteGuard, mpsc, session_state,
};

pub(super) async fn route_session_notification(
    notification_guard: &SessionRouteGuard,
    supervisor: &AcpSessionSupervisor,
    manager: &AcpAgentManagerHandle,
    notifications: &mpsc::Sender<RoutedSessionNotification>,
    notification: SessionNotification,
) -> AcpResult<()> {
    let Some(routed) = routed_session_notification(notification_guard, notification) else {
        return Ok(());
    };
    // Session state is applied even for a replay. A replay is chronological, so
    // it ends on the session's current mode, config, and commands, and only the
    // first two come back on the load response - dropping the whole
    // notification would lose the agent's command list until it resent one.
    if let Some(title) =
        session_state::apply_session_update(supervisor, &routed.notification.update)
    {
        manager.record_runtime_session_title_best_effort(
            &routed.session_id,
            &routed.acp_id,
            &title,
        );
    }
    // The conversation itself is history harness already stored, so forwarding
    // it would write a second copy of every turn and show the Monitor the whole
    // backlog as if it had just been said.
    if notification_guard.is_replaying(&routed.notification.session_id) {
        log_replayed_notification(&routed.notification.session_id);
        return Ok(());
    }
    notifications
        .send(routed)
        .await
        .map_err(|error| AcpError::new(-32603, format!("queue ACP event: {error}")))?;
    Ok(())
}

fn routed_session_notification(
    notification_guard: &SessionRouteGuard,
    notification: SessionNotification,
) -> Option<RoutedSessionNotification> {
    let target = match notification_guard.ensure_known(&notification.session_id) {
        Ok(target) => target,
        Err(route_error) => {
            log_unroutable_notification(&notification.session_id, route_error.reason.as_str());
            return None;
        }
    };
    Some(RoutedSessionNotification {
        acp_id: target.acp_id,
        session_id: target.session_id,
        notification,
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_unroutable_notification(session_id: &SessionId, reason: &str) {
    tracing::debug!(
        session_id = %session_id,
        reason,
        "dropping unroutable ACP notification"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_replayed_notification(session_id: &SessionId) {
    tracing::debug!(
        session_id = %session_id,
        "dropping ACP notification replayed by session/load"
    );
}

pub(super) async fn report_protocol_result(
    result: AcpResult<()>,
    disconnect_tx: mpsc::Sender<DisconnectReason>,
) {
    let Err(error) = result else {
        return;
    };
    warn_protocol_error(&error);
    let _ = disconnect_tx
        .send(disconnect_reason_from_error(&error))
        .await;
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_protocol_error(error: &AcpError) {
    tracing::warn!(%error, "ACP protocol task stopped");
}

pub(super) fn disconnect_reason_from_error(error: &AcpError) -> DisconnectReason {
    if matches!(error.code, ErrorCode::AuthRequired) {
        DisconnectReason::AuthRequired
    } else if matches!(error.code, ErrorCode::Other(ACP_DEADLINE_EXCEEDED))
        && error.message.contains("session/initialize")
    {
        DisconnectReason::InitializeTimeout
    } else if matches!(error.code, ErrorCode::Other(ACP_DEADLINE_EXCEEDED))
        && error.message.contains("session/prompt")
    {
        DisconnectReason::PromptTimeout
    } else if is_transport_closed_error(error) {
        DisconnectReason::TransportClosed
    } else {
        DisconnectReason::StdioClosed
    }
}

fn is_transport_closed_error(error: &AcpError) -> bool {
    let message = error.message.to_ascii_lowercase();
    message.contains("transport closed")
        || message.contains("connection closed")
        || message.contains("broken pipe")
        || message.contains("unexpected eof")
}
