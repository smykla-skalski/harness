use super::super::{CliError, LeaderTransferRequest, SessionDetail, SessionEndRequest};
use crate::daemon::protocol::{SessionArchiveRequest, SessionArchiveResponse};

/// Transfer session leadership through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub fn transfer_leader(
    session_id: &str,
    request: &LeaderTransferRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::transfer_leader(session_id, request, db)
}

/// End a session through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub fn end_session(
    session_id: &str,
    request: &SessionEndRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::end_session(session_id, request, db)
}

/// Archive a session so daemon reads stop surfacing it to Monitor clients.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or archiving fails.
pub fn archive_session(
    session_id: &str,
    request: &SessionArchiveRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionArchiveResponse, CliError> {
    harness_daemon_session_service::archive_session(session_id, request, db)
}
