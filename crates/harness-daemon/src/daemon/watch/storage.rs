use harness_daemon_watch::{AsyncWatchStorage, WatchStorage};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::task_board::automation_snapshot::TaskBoardAutomationSnapshot;

use crate::daemon::db::DaemonDbSessionResync;
use crate::daemon::db::task_board::prelude::TaskBoardAutomationSchedulerQueries;
use crate::daemon::db::{
    AsyncChangeTrackingQueries, AsyncDaemonDb, ChangeTrackingQueries,
    PreparedRuntimeTranscriptResync, PreparedSessionResync, SessionWriteQueries,
    prepare_runtime_transcript_resync, prepare_session_resync,
};
use crate::daemon::db_handle::{AsyncDaemonDbHandle, DaemonDbOwnedHandle};

pub struct DaemonPreparedRuntimeTranscriptResync(PreparedRuntimeTranscriptResync);
pub struct DaemonPreparedSessionResync(PreparedSessionResync);

impl AsyncWatchStorage for AsyncDaemonDbHandle {
    async fn current_change_sequence(&self) -> Result<i64, CliError> {
        <AsyncDaemonDb as AsyncChangeTrackingQueries>::current_change_sequence(&self.0).await
    }

    async fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        <AsyncDaemonDb as AsyncChangeTrackingQueries>::load_change_tracking_since(
            &self.0,
            last_change_seq,
        )
        .await
    }

    async fn task_board_automation_snapshot(
        &self,
    ) -> Result<TaskBoardAutomationSnapshot, CliError> {
        <AsyncDaemonDb as TaskBoardAutomationSchedulerQueries>::task_board_automation_snapshot(
            &self.0,
        )
        .await
    }
}

impl WatchStorage for DaemonDbOwnedHandle {
    type PreparedRuntimeTranscriptResync = DaemonPreparedRuntimeTranscriptResync;
    type PreparedSessionResync = DaemonPreparedSessionResync;

    fn current_change_sequence(&self) -> Result<i64, CliError> {
        <crate::daemon::db::DaemonDb as SessionWriteQueries>::current_change_sequence(&self.0)
    }

    fn load_change_tracking_since(
        &self,
        last_change_seq: i64,
    ) -> Result<Vec<(String, i64)>, CliError> {
        <crate::daemon::db::DaemonDb as ChangeTrackingQueries>::load_change_tracking_since(
            &self.0,
            last_change_seq,
        )
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
        DaemonDbSessionResync::apply_prepared_session_resync(&self.0, &prepared.0)
    }

    fn apply_prepared_runtime_transcript_resync(
        &self,
        prepared: &Self::PreparedRuntimeTranscriptResync,
    ) -> Result<(), CliError> {
        DaemonDbSessionResync::apply_prepared_runtime_transcript_resync(&self.0, &prepared.0)
    }
}
