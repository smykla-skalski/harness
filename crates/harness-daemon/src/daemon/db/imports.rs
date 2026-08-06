use harness_daemon_db_queries::{
    prepare_agent_conversation_imports_and_activity, prepare_runtime_transcript_resync_for_agents,
    session_state_import_required,
};

use super::DaemonDbConversation;
use super::DaemonDbTimeline;
use super::{
    CliError, DaemonDb, PreparedRuntimeTranscriptResync, PreparedSessionResync,
    PreparedTaskCheckpointImport, TaskReviewRebuild, clear_session_conversation_events,
    daemon_index, daemon_snapshot,
};
use crate::daemon::db::prelude::*;

/// Kept separate from [`harness_daemon_db_queries::DaemonDbImports`] (rather
/// than folded into it) because its prepared-resync argument types stay
/// `pub(crate)`: a `pub` trait exposing a `pub(crate)` type in its signature
/// is a real privacy mismatch, not just a lint to silence. Stays in
/// `harness-daemon` because `apply_prepared_session_resync` needs
/// `rebuild_session_timeline_from_resolved` (`DaemonDbTimeline`, not yet
/// extracted).
pub(crate) trait DaemonDbSessionResync {
    /// Apply a previously prepared session re-sync to the daemon database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn apply_prepared_session_resync(
        &self,
        prepared: &PreparedSessionResync,
    ) -> Result<(), CliError>;

    /// Apply a prepared transcript-only refresh for matching runtime agents.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError>;
}

impl DaemonDbSessionResync for DaemonDb {
    fn apply_prepared_session_resync(
        &self,
        prepared: &PreparedSessionResync,
    ) -> Result<(), CliError> {
        if !session_state_import_required(
            self,
            &prepared.resolved.state.session_id,
            prepared.resolved.state.state_version,
        )? {
            return Ok(());
        }
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

        for task_id in prepared.resolved.state.tasks.keys() {
            let reviews = daemon_index::load_task_reviews(
                &prepared.resolved.project,
                &prepared.resolved.state.session_id,
                task_id,
            )?;
            self.rebuild_task_reviews(&prepared.resolved.state.session_id, task_id, &reviews)?;
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

    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError> {
        for agent in &prepared.agents {
            let (stored_count, stored_max_sequence) =
                self.conversation_event_cursor(&prepared.session_id, &agent.agent_id)?;
            if agent.events.len() < stored_count {
                // The file transcript shrank (rotation or truncation); fully
                // replace so removed rows are dropped from the cache.
                self.sync_conversation_events(
                    &prepared.session_id,
                    &agent.agent_id,
                    &agent.runtime,
                    &agent.events,
                )?;
            } else {
                // Append-only growth: upsert only the new tail past the stored
                // cursor instead of rewriting the entire transcript.
                self.upsert_conversation_events_after(
                    &prepared.session_id,
                    &agent.agent_id,
                    &agent.runtime,
                    &agent.events,
                    stored_max_sequence,
                )?;
            }
            self.upsert_agent_activity(&prepared.session_id, &agent.activity)?;
        }

        self.bump_change(&prepared.session_id)?;
        Ok(())
    }
}

/// Prepare a session re-sync by loading all file-backed data before any
/// caller takes the shared daemon database lock.
///
/// Free function, not a `DaemonDb` method: it never touches `self`, so
/// callers outside `db` (the watch loop, `service::read_reconciliation`)
/// reach it without naming the concrete db type.
///
/// # Errors
/// Returns [`CliError`] on discovery, I/O, or parse failures.
pub(crate) fn prepare_session_resync(session_id: &str) -> Result<PreparedSessionResync, CliError> {
    let resolved = daemon_index::resolve_session(session_id)?;
    prepare_session_import_from_resolved(&resolved)
}

/// Prepare a session import from a pre-discovered resolved session. Free
/// function for the same reason as [`prepare_session_resync`].
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
/// can be found. Free function for the same reason as
/// [`prepare_session_resync`].
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
        session_id: resolved.state.session_id,
        agents,
    }))
}
