use harness_daemon_db_core::DaemonDb;
use harness_kernel::errors::CliError;
use harness_protocol::session::SessionState;
use harness_session::index::{self as daemon_index, DiscoveredProject};

use crate::conversation::{
    DaemonDbConversation, clear_session_conversation_events,
    prepare_agent_conversation_imports_and_activity,
};
use crate::diagnostics::import_daemon_events;
use crate::session_data::SessionCoreQueries;
use crate::signals::SignalIndexQueries;
use crate::writes::SessionWriteQueries;

/// Summary of what was imported from file-based storage.
#[derive(Debug, Default)]
pub struct ImportResult {
    pub projects: usize,
    pub sessions: usize,
}

/// Summary of background file reconciliation.
#[derive(Debug, Default)]
pub struct ReconcileResult {
    pub projects: usize,
    pub sessions_imported: usize,
    pub sessions_skipped: usize,
}

pub trait DaemonDbImports {
    /// Import all file-backed sessions and projects into the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    fn import_from_files(&self) -> Result<ImportResult, CliError>;

    /// Reconcile file-discovered sessions into the database, only
    /// importing sessions that are new or have a higher `state_version`
    /// than the DB copy. Daemon-first sessions (only in `SQLite`) are
    /// never touched.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    fn reconcile_sessions(
        &self,
        projects: &[daemon_index::DiscoveredProject],
        sessions: &[daemon_index::ResolvedSession],
    ) -> Result<ReconcileResult, CliError>;

    /// Discover projects and sessions from files, then reconcile into
    /// the database. Only imports sessions that are new or have a higher
    /// `state_version` than existing DB records. Safe to call while the
    /// daemon is serving - daemon-first sessions are never overwritten.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    fn reconcile_from_files(&self) -> Result<ReconcileResult, CliError>;
}

/// Whether a file-discovered session's `state_version` is newer than the
/// database copy (or the session doesn't exist in the database yet).
///
/// Shared with `harness-daemon`'s `DaemonDbSessionResync::apply_prepared_session_resync`
/// remnant, which stayed behind because it needs `rebuild_session_timeline_from_resolved`
/// (`DaemonDbTimeline`, not yet extracted).
///
/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn session_state_import_required(
    db: &DaemonDb,
    session_id: &str,
    file_state_version: u64,
) -> Result<bool, CliError> {
    let db_version = db.session_state_version(session_id)?;
    let file_version = i64::try_from(file_state_version).unwrap_or(i64::MAX);
    Ok(db_version.is_none_or(|version| version < file_version))
}

impl DaemonDbImports for DaemonDb {
    fn import_from_files(&self) -> Result<ImportResult, CliError> {
        let projects = daemon_index::discover_projects()?;
        let sessions = daemon_index::discover_sessions_for(&projects, true)?;

        let mut result = ImportResult::default();

        for project in &projects {
            self.sync_project(project)?;
            result.projects += 1;
        }

        for resolved in &sessions {
            self.sync_session(&resolved.project.project_id, &resolved.state)?;
            result.sessions += 1;

            import_session_log(self, &resolved.project, &resolved.state.session_id)?;
            import_session_checkpoints(self, &resolved.project, &resolved.state)?;
            import_session_signals(self, resolved)?;
            import_session_activity_and_conversation_events(self, resolved)?;
        }

        import_daemon_events(self)?;
        self.bump_change("global")?;

        Ok(result)
    }

    fn reconcile_sessions(
        &self,
        projects: &[daemon_index::DiscoveredProject],
        sessions: &[daemon_index::ResolvedSession],
    ) -> Result<ReconcileResult, CliError> {
        let mut result = ReconcileResult::default();

        for project in projects {
            self.sync_project(project)?;
            result.projects += 1;
        }

        for resolved in sessions {
            if !session_state_import_required(
                self,
                &resolved.state.session_id,
                resolved.state.state_version,
            )? {
                result.sessions_skipped += 1;
                continue;
            }

            self.sync_session(&resolved.project.project_id, &resolved.state)?;
            import_session_log(self, &resolved.project, &resolved.state.session_id)?;
            import_session_checkpoints(self, &resolved.project, &resolved.state)?;
            import_session_signals(self, resolved)?;
            import_session_activity_and_conversation_events(self, resolved)?;
            result.sessions_imported += 1;
        }

        if result.sessions_imported > 0 {
            self.bump_change("global")?;
        }

        Ok(result)
    }

    fn reconcile_from_files(&self) -> Result<ReconcileResult, CliError> {
        let projects = daemon_index::discover_projects()?;
        let sessions = daemon_index::discover_sessions_for(&projects, true)?;
        self.reconcile_sessions(&projects, &sessions)
    }
}

fn import_session_log(
    db: &DaemonDb,
    project: &DiscoveredProject,
    session_id: &str,
) -> Result<(), CliError> {
    let entries = daemon_index::load_log_entries(project, session_id)?;
    for entry in &entries {
        db.append_log_entry(entry)?;
    }
    Ok(())
}

fn import_session_checkpoints(
    db: &DaemonDb,
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<(), CliError> {
    for task_id in state.tasks.keys() {
        let checkpoints = daemon_index::load_task_checkpoints(project, &state.session_id, task_id)?;
        for checkpoint in &checkpoints {
            db.append_checkpoint(&state.session_id, checkpoint)?;
        }
    }
    Ok(())
}

fn import_session_signals(
    db: &DaemonDb,
    resolved: &daemon_index::ResolvedSession,
) -> Result<(), CliError> {
    let signals = harness_daemon_snapshot::load_signals_for(&resolved.project, &resolved.state)?;
    db.sync_signal_index(&resolved.state.session_id, &signals)
}

fn import_session_activity_and_conversation_events(
    db: &DaemonDb,
    resolved: &daemon_index::ResolvedSession,
) -> Result<(), CliError> {
    let (activities, conversation_events) = prepare_agent_conversation_imports_and_activity(
        &resolved.state,
        |agent_id, runtime, session_key| {
            daemon_index::load_conversation_events(
                &resolved.project,
                runtime,
                session_key,
                agent_id,
            )
        },
    )?;
    db.sync_agent_activity(&resolved.state.session_id, &activities)?;
    clear_session_conversation_events(&db.conn, &resolved.state.session_id)?;
    for import in &conversation_events {
        db.sync_conversation_events(
            &resolved.state.session_id,
            &import.agent_id,
            &import.runtime,
            &import.events,
        )?;
    }
    Ok(())
}
