use super::{CliError, SessionDetail, SessionLeaveRequest};

/// Mark an agent as disconnected through the shared daemon session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the leave fails.
pub fn leave_session(
    session_id: &str,
    request: &SessionLeaveRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::leave_session(session_id, request, db)
}

/// Mark an agent as disconnected through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the leave fails.
pub(crate) async fn leave_session_async(
    session_id: &str,
    request: &SessionLeaveRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::leave_session_async(session_id, request, async_db).await
}
