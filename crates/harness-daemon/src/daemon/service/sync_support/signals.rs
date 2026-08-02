use crate::daemon::db::DaemonDb;

use super::context::session_not_found;
use super::{AckResult, CliError, Path, snapshot};
use crate::daemon::db::prelude::*;

pub(crate) fn record_signal_ack(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    result: AckResult,
    project_dir: &Path,
    db: Option<&DaemonDb>,
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
    db: &DaemonDb,
) -> Result<(), CliError> {
    harness_daemon_session_service::reconcile_expired_pending_signals(session_id, db)
}

pub(crate) fn refresh_signal_index_for_db(db: &DaemonDb, session_id: &str) -> Result<(), CliError> {
    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(session_id, &signals)
}
