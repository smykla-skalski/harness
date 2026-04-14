use super::{
    CliError, DaemonDb, DiscoveredProject, ImportResult, PreparedRuntimeTranscriptResync,
    PreparedSessionResync, PreparedTaskCheckpointImport, ReconcileResult, SessionState,
    clear_session_conversation_events, daemon_index, daemon_snapshot, import_daemon_events,
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
};

impl DaemonDb {
    /// Import all file-backed sessions and projects into the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    pub fn import_from_files(&self) -> Result<ImportResult, CliError> {
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

    /// Reconcile file-discovered sessions into the database, only
    /// importing sessions that are new or have a higher `state_version`
    /// than the DB copy. Daemon-first sessions (only in `SQLite`) are
    /// never touched.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    pub fn reconcile_sessions(
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
            let db_version = self.session_state_version(&resolved.state.session_id)?;
            let file_version = i64::try_from(resolved.state.state_version).unwrap_or(i64::MAX);

            if db_version.is_some_and(|version| version >= file_version) {
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

    /// Discover projects and sessions from files, then reconcile into
    /// the database. Only imports sessions that are new or have a higher
    /// `state_version` than existing DB records. Safe to call while the
    /// daemon is serving - daemon-first sessions are never overwritten.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery or SQL failures.
    pub fn reconcile_from_files(&self) -> Result<ReconcileResult, CliError> {
        let projects = daemon_index::discover_projects()?;
        let sessions = daemon_index::discover_sessions_for(&projects, true)?;
        self.reconcile_sessions(&projects, &sessions)
    }
    /// Re-sync a session from its file-backed state into the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery, I/O, or SQL failures.
    pub fn resync_session(&self, session_id: &str) -> Result<(), CliError> {
        let prepared = Self::prepare_session_resync(session_id)?;
        self.apply_prepared_session_resync(&prepared)
    }

    /// Prepare a session re-sync by loading all file-backed data before any
    /// caller takes the shared daemon database lock.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery, I/O, or parse failures.
    pub(crate) fn prepare_session_resync(
        session_id: &str,
    ) -> Result<PreparedSessionResync, CliError> {
        let resolved = daemon_index::resolve_session(session_id)?;
        Self::prepare_session_import_from_resolved(&resolved)
    }

    /// Prepare a session import from a pre-discovered resolved session.
    ///
    /// # Errors
    /// Returns [`CliError`] on I/O or parse failures.
    pub(crate) fn prepare_session_import_from_resolved(
        resolved: &daemon_index::ResolvedSession,
    ) -> Result<PreparedSessionResync, CliError> {
        let log_entries =
            daemon_index::load_log_entries(&resolved.project, &resolved.state.session_id)?;

        let mut task_checkpoints = Vec::new();
        for task_id in resolved.state.tasks.keys() {
            let checkpoints = daemon_index::load_task_checkpoints(
                &resolved.project,
                &resolved.state.session_id,
                task_id,
            )?;
            task_checkpoints.push(PreparedTaskCheckpointImport { checkpoints });
        }

        let signals = daemon_snapshot::load_signals_for(&resolved.project, &resolved.state)?;
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

        Ok(PreparedSessionResync {
            resolved: resolved.clone(),
            log_entries,
            task_checkpoints,
            signals,
            activities,
            conversation_events,
        })
    }

    /// Prepare a transcript-only refresh for one runtime session within an
    /// orchestration session. Falls back to full resync when no matching agent
    /// can be found.
    ///
    /// # Errors
    /// Returns [`CliError`] on discovery, I/O, or parse failures.
    pub(crate) fn prepare_runtime_transcript_resync(
        session_id: &str,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Option<PreparedRuntimeTranscriptResync>, CliError> {
        let resolved = daemon_index::resolve_session(session_id)?;
        let agents = prepare_runtime_transcript_resync_for_agents(
            &resolved.state,
            runtime_name,
            runtime_session_id,
            |agent_id, runtime, session_key| {
                daemon_index::load_conversation_events(
                    &resolved.project,
                    runtime,
                    session_key,
                    agent_id,
                )
            },
        )?;
        if agents.is_empty() {
            return Ok(None);
        }

        Ok(Some(PreparedRuntimeTranscriptResync {
            session_id: resolved.state.session_id.clone(),
            agents,
        }))
    }

    /// Apply a previously prepared session re-sync to the daemon database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) fn apply_prepared_session_resync(
        &self,
        prepared: &PreparedSessionResync,
    ) -> Result<(), CliError> {
        self.sync_session(
            &prepared.resolved.project.project_id,
            &prepared.resolved.state,
        )?;

        for entry in &prepared.log_entries {
            self.append_log_entry(entry)?;
        }
        for import in &prepared.task_checkpoints {
            for checkpoint in &import.checkpoints {
                self.append_checkpoint(&prepared.resolved.state.session_id, checkpoint)?;
            }
        }

        self.sync_signal_index(&prepared.resolved.state.session_id, &prepared.signals)?;
        self.sync_agent_activity(&prepared.resolved.state.session_id, &prepared.activities)?;

        clear_session_conversation_events(&self.conn, &prepared.resolved.state.session_id)?;
        for import in &prepared.conversation_events {
            self.sync_conversation_events(
                &prepared.resolved.state.session_id,
                &import.agent_id,
                &import.runtime,
                &import.events,
            )?;
        }

        self.rebuild_session_timeline_from_resolved(&prepared.resolved)?;

        self.bump_change(&prepared.resolved.state.session_id)?;
        self.bump_change("global")?;
        Ok(())
    }

    /// Apply a prepared transcript-only refresh for matching runtime agents.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError> {
        for agent in &prepared.agents {
            self.sync_conversation_events(
                &prepared.session_id,
                &agent.agent_id,
                &agent.runtime,
                &agent.events,
            )?;
            self.upsert_agent_activity(&prepared.session_id, &agent.activity)?;
        }

        self.bump_change(&prepared.session_id)?;
        Ok(())
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
    let signals = daemon_snapshot::load_signals_for(&resolved.project, &resolved.state)?;
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
