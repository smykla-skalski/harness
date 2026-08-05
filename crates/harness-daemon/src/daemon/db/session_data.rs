use std::path::Path;

use harness_daemon_db_queries::SessionCoreQueries;

use crate::daemon::db::imports::DaemonDbSessionResync;
use crate::daemon::index as daemon_index;
use crate::session::storage as session_storage;

use super::{
    CliError, DaemonDb, SessionState, prepare_session_import_from_resolved, prepare_session_resync,
};

/// Session-state load paired with a file-backed resync repair, kept out of
/// [`SessionCoreQueries`] (now in `harness-daemon-db-queries`) because it
/// needs `imports.rs`'s resync helpers, not yet extracted.
pub(crate) trait SessionMutationRefresh {
    /// Load session state by ID for an in-place mutation.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn load_session_state_for_mutation(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionState>, CliError>;
}

impl SessionMutationRefresh for DaemonDb {
    fn load_session_state_for_mutation(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionState>, CliError> {
        session_storage::validate_session_id(session_id)?;
        refresh_session_state_for_mutation(self, session_id)?;
        SessionCoreQueries::load_session_state(self, session_id)
    }
}

fn refresh_session_state_for_mutation(db: &DaemonDb, session_id: &str) -> Result<(), CliError> {
    let db_version = db.session_state_version(session_id)?;
    let Some(db_version) = db_version else {
        let prepared = match prepare_session_resync(session_id) {
            Ok(prepared) => Some(prepared),
            Err(error) if error.code() == "KSRCLI090" => None,
            Err(error) => return Err(error),
        };
        if let Some(prepared) = prepared {
            db.apply_prepared_session_resync(&prepared)?;
        }
        return Ok(());
    };
    let Some(project_dir) = db.project_dir_for_session(session_id)? else {
        return Ok(());
    };
    let project_dir = Path::new(&project_dir);
    let layout = session_storage::layout_from_project_dir(project_dir, session_id)?;
    let Some(file_state) = session_storage::load_state(&layout)? else {
        return Ok(());
    };
    let file_version = i64::try_from(file_state.state_version).unwrap_or(i64::MAX);
    if db_version >= file_version {
        return Ok(());
    }
    let resolved = daemon_index::ResolvedSession {
        project: daemon_index::discovered_project_for_checkout(project_dir),
        state: file_state,
    };
    let prepared = prepare_session_import_from_resolved(&resolved)?;
    db.apply_prepared_session_resync(&prepared)?;
    Ok(())
}
