use super::{AckResult, CliError, Path, session_not_found, snapshot};
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::DaemonDbOwnedHandle;

pub(crate) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&DaemonDbOwnedHandle>,
) -> Result<(), CliError> {
    harness_daemon_session_service::record_signal_ack(
        session_id,
        agent_id,
        signal_id,
        result,
        project_dir,
        db,
    )
}

pub(crate) fn reconcile_expired_pending_signals_for_db(
    session_id: &str,
    db: &DaemonDbOwnedHandle,
) -> Result<(), CliError> {
    harness_daemon_session_service::reconcile_expired_pending_signals(session_id, db)
}

pub(crate) fn refresh_signal_index_for_db(
    db: &DaemonDbOwnedHandle,
    session_id: &str,
) -> Result<(), CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(session_id, &signals)
}
