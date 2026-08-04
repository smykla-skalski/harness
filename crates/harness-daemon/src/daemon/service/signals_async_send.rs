use harness_daemon_session_service::SignalWake;
use harness_kernel::errors::CliError;

use super::super::agent_tui::AgentTuiManagerHandle;
use super::super::protocol::{SessionDetail, SignalSendRequest};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(crate) async fn send_signal_async(
    session_id: &str,
    request: &SignalSendRequest,
    db: &AsyncDaemonDbHandle,
    manager: Option<&AgentTuiManagerHandle>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::send_signal_async(
        session_id,
        request,
        db,
        manager.map(|manager| manager as &dyn SignalWake),
    )
    .await
}
