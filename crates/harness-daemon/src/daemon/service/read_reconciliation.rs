use std::path::PathBuf;

use super::{CliError, Path, ResolvedSession, index, session_not_found};

pub(crate) fn liveness_project_dir_for_resolved(resolved: &ResolvedSession) -> Option<PathBuf> {
    harness_daemon_session_service::liveness_project_dir_for_resolved(resolved)
}

pub(crate) fn sync_resolved_liveness(
    db: &super::db::DaemonDb,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    harness_daemon_session_service::sync_resolved_liveness(db, resolved, project_dir)
}

pub(crate) async fn sync_resolved_liveness_async(
    async_db: &super::db::AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    harness_daemon_session_service::sync_resolved_liveness_async(async_db, resolved, project_dir)
        .await
}

pub(crate) fn refresh_resolved_session_from_files_if_newer(
    db: &super::db::DaemonDb,
    resolved: &mut ResolvedSession,
) -> Result<(), CliError> {
    let file_resolved = match index::resolve_session(&resolved.state.session_id) {
        Ok(file_resolved) => file_resolved,
        Err(error) if error.code() == "KSRCLI090" => return Ok(()),
        Err(error) => return Err(error),
    };
    if file_resolved.state.state_version <= resolved.state.state_version {
        return Ok(());
    }

    let session_id = resolved.state.session_id.clone();
    let prepared = super::db::prepare_session_import_from_resolved(&file_resolved)?;
    db.apply_prepared_session_resync(&prepared)?;
    *resolved = db
        .resolve_session(&session_id)?
        .ok_or_else(|| session_not_found(&session_id))?;
    Ok(())
}
