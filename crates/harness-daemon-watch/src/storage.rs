use harness_kernel::errors::CliError;
use harness_protocol::daemon::task_board::automation_snapshot::TaskBoardAutomationSnapshot;

pub trait AsyncWatchStorage: Send + Sync {
    fn current_change_sequence(&self) -> impl Future<Output = Result<i64, CliError>> + Send;

    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> impl Future<Output = Result<Vec<(String, i64)>, CliError>> + Send;

    fn task_board_automation_snapshot(
        &self,
    ) -> impl Future<Output = Result<TaskBoardAutomationSnapshot, CliError>> + Send;
}

pub trait WatchStorage: Send {
    type PreparedSessionResync: Send;
    type PreparedRuntimeTranscriptResync: Send;

    /// # Errors
    /// Returns an error when the current change sequence cannot be read.
    fn current_change_sequence(&self) -> Result<i64, CliError>;

    /// # Errors
    /// Returns an error when change-tracking rows cannot be read.
    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError>;

    /// # Errors
    /// Returns an error when session state cannot be prepared for import.
    fn prepare_session_resync(session_id: &str) -> Result<Self::PreparedSessionResync, CliError>;

    /// # Errors
    /// Returns an error when a runtime transcript cannot be prepared for import.
    fn prepare_runtime_transcript_resync(
        session_id: &str,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Option<Self::PreparedRuntimeTranscriptResync>, CliError>;

    /// # Errors
    /// Returns an error when the prepared session state cannot be stored.
    fn apply_prepared_session_resync(
        &self,
        prepared: &Self::PreparedSessionResync,
    ) -> Result<(), CliError>;

    /// # Errors
    /// Returns an error when the prepared runtime transcript cannot be stored.
    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &Self::PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError>;
}
