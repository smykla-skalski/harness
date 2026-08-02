use harness_daemon_watch::{AsyncWatchStorage, WatchStorage};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::task_board::automation_snapshot::TaskBoardAutomationSnapshot;

use crate::daemon::db::imports::DaemonDbSessionResync;
use crate::daemon::db::{
    AsyncDaemonDb, DaemonDb, PreparedRuntimeTranscriptResync, PreparedSessionResync,
    prepare_runtime_transcript_resync, prepare_session_resync,
};

pub struct DaemonPreparedRuntimeTranscriptResync(PreparedRuntimeTranscriptResync);
pub struct DaemonPreparedSessionResync(PreparedSessionResync);

impl AsyncWatchStorage for AsyncDaemonDb {
    async fn current_change_sequence(&self) -> Result<i64, CliError> {
        Self::current_change_sequence(self).await
    }

    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        Self::load_change_tracking_since(self, last_change_seq).await
    }

    async fn task_board_automation_snapshot(
        &self,
    ) -> Result<TaskBoardAutomationSnapshot, CliError> {
        Self::task_board_automation_snapshot(self).await
    }
}

impl WatchStorage for DaemonDb {
    type PreparedRuntimeTranscriptResync = DaemonPreparedRuntimeTranscriptResync;
    type PreparedSessionResync = DaemonPreparedSessionResync;

    fn current_change_sequence(&self) -> Result<i64, CliError> {
        Self::current_change_sequence(self)
    }

    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        Self::load_change_tracking_since(self, last_change_seq)
    }

    fn prepare_session_resync(session_id: &str) -> Result<Self::PreparedSessionResync, CliError> {
        prepare_session_resync(session_id).map(DaemonPreparedSessionResync)
    }

    fn prepare_runtime_transcript_resync(
        session_id: &str,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Option<Self::PreparedRuntimeTranscriptResync>, CliError> {
        prepare_runtime_transcript_resync(session_id, runtime_name, runtime_session_id)
            .map(|prepared| prepared.map(DaemonPreparedRuntimeTranscriptResync))
    }

    fn apply_prepared_session_resync(
        &self,
        prepared: &Self::PreparedSessionResync,
    ) -> Result<(), CliError> {
        DaemonDbSessionResync::apply_prepared_session_resync(self, &prepared.0)
    }

    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &Self::PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError> {
        DaemonDbSessionResync::apply_prepared_runtime_transcript_resync(self, &prepared.0)
    }
}
