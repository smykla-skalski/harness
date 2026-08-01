use std::future::Future;
use std::time::Duration;

use harness_agents::runtime::signal::Signal;
use harness_kernel::errors::CliError;
use harness_protocol::timeline::{TimelineEntry, TimelineWindowRequest, TimelineWindowResponse};
use harness_session::index::{DiscoveredProject, ResolvedSession};
use harness_session::types::{SessionLogEntry, SessionSignalRecord, SessionState};
use harness_session::wire::{
    AgentToolActivitySummary, ProjectSummary, SessionDetail, SessionSummary,
};

/// A pending indexed signal whose effective status has expired.
#[derive(Debug, Clone)]
pub struct ExpiredPendingSignalIndexRecord {
    pub runtime: String,
    pub agent_id: String,
    pub signal: Signal,
}

/// Synchronous persistence needed by signal delivery.
pub trait SignalStorage {
    /// # Errors
    /// Returns an error when the session cannot be loaded.
    fn load_session_state_for_mutation(
        &self,
        session_id: &str,
    ) -> Result<Option<SessionState>, CliError>;

    /// # Errors
    /// Returns an error when the session cannot be loaded.
    fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError>;

    /// # Errors
    /// Returns an error when the session log cannot be loaded.
    fn load_session_log(&self, session_id: &str) -> Result<Vec<SessionLogEntry>, CliError>;

    /// # Errors
    /// Returns an error when the project cannot be resolved.
    fn project_id_for_session(&self, session_id: &str) -> Result<Option<String>, CliError>;

    /// # Errors
    /// Returns an error when the project directory cannot be resolved.
    fn project_dir_for_session(&self, session_id: &str) -> Result<Option<String>, CliError>;

    /// # Errors
    /// Returns an error when session state cannot be saved.
    fn save_session_state(&self, project_id: &str, state: &SessionState) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when the session cannot be resolved.
    fn resolve_session(&self, session_id: &str) -> Result<Option<ResolvedSession>, CliError>;

    /// # Errors
    /// Returns an error when indexed signals cannot be loaded.
    fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError>;

    /// # Errors
    /// Returns an error when indexed signals cannot be updated.
    fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when the signal index cannot be refreshed.
    fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when a log entry cannot be appended.
    fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when the change sequence cannot be advanced.
    fn bump_change(&self, scope: &str) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when the session detail cannot be assembled.
    fn session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError>;

    /// # Errors
    /// Returns an error when the active flag cannot be cleared.
    fn mark_session_inactive(&self, session_id: &str) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when indexed signals cannot be loaded.
    fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> Result<Vec<ExpiredPendingSignalIndexRecord>, CliError>;

    /// # Errors
    /// Returns an error on project discovery failures.
    fn list_project_summaries(&self) -> Result<Vec<ProjectSummary>, CliError>;

    /// # Errors
    /// Returns an error on session discovery failures.
    fn list_session_summaries_full(&self) -> Result<Vec<SessionSummary>, CliError>;

    /// # Errors
    /// Returns an error on SQL failures.
    fn sync_project(&self, project: &DiscoveredProject) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error on SQL failures.
    fn create_session_record(&self, project_id: &str, state: &SessionState)
    -> Result<(), CliError>;

    /// # Errors
    /// Returns an error on SQL failures.
    fn delete_session_row(&self, session_id: &str) -> Result<bool, CliError>;
}

/// Asynchronous persistence needed by signal delivery.
pub trait AsyncSignalStorage: Send + Sync {
    fn resolve_session(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Option<ResolvedSession>, CliError>> + Send;

    fn bump_change(&self, scope: &str) -> impl Future<Output = Result<(), CliError>> + Send;

    fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn load_signals(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<SessionSignalRecord>, CliError>> + Send;

    fn update_session_state_immediate<F, T>(
        &self,
        session_id: &str,
        update: F,
    ) -> impl Future<Output = Result<T, CliError>> + Send
    where
        F: FnOnce(&mut SessionState) -> Result<T, CliError> + Send,
        T: Send;

    fn append_log_entry(
        &self,
        entry: &SessionLogEntry,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn session_detail(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<SessionDetail, CliError>> + Send;

    fn sync_file_state(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<ExpiredPendingSignalIndexRecord>, CliError>> + Send;

    fn list_project_summaries(
        &self,
    ) -> impl Future<Output = Result<Vec<ProjectSummary>, CliError>> + Send;

    fn list_session_summaries(
        &self,
    ) -> impl Future<Output = Result<Vec<SessionSummary>, CliError>> + Send;

    fn resolve_runtime_session_agents(
        &self,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> impl Future<Output = Result<Vec<(String, String)>, CliError>> + Send;

    fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<AgentToolActivitySummary>, CliError>> + Send;

    fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &TimelineWindowRequest,
    ) -> impl Future<Output = Result<Option<TimelineWindowResponse>, CliError>> + Send;

    fn load_session_acp_transcript_entries(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<TimelineEntry>, CliError>> + Send;

    fn list_liveness_candidate_ids(
        &self,
    ) -> impl Future<Output = Result<Vec<String>, CliError>> + Send;

    fn sync_project(
        &self,
        project: &DiscoveredProject,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn create_session_record(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    fn delete_session_row(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<bool, CliError>> + Send;
}

/// Active wake transport used for best-effort signal delivery.
pub trait SignalWake: Send + Sync {
    fn ack_timeout_override(&self) -> Option<Duration>;

    /// # Errors
    /// Returns an error when the managed runtime cannot be prompted.
    fn prompt(&self, managed_id: &str, prompt: &str) -> Result<bool, CliError>;
}
