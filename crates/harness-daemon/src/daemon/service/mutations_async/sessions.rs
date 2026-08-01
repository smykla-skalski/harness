use super::super::{
    CliError, LeaderTransferRequest, SessionDetail, SessionEndRequest, db::AsyncDaemonDb,
};
use crate::daemon::protocol::{SessionArchiveRequest, SessionArchiveResponse};

/// Transfer session leadership through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub(crate) async fn transfer_leader_async(
    session_id: &str,
    request: &LeaderTransferRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::transfer_leader_async(session_id, request, async_db).await
}

/// End a session through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub(crate) async fn end_session_async(
    session_id: &str,
    request: &SessionEndRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::end_session_async(session_id, request, async_db).await
}

/// Archive a session so daemon reads stop surfacing it to Monitor clients.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or archiving fails.
pub(crate) async fn archive_session_async(
    session_id: &str,
    request: &SessionArchiveRequest,
    async_db: &AsyncDaemonDb,
) -> Result<SessionArchiveResponse, CliError> {
    harness_daemon_session_service::archive_session_async(session_id, request, async_db).await
}
