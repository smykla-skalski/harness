use harness_daemon_session_service::AsyncSignalStorage;
use harness_kernel::errors::CliError;
use harness_session::index::ResolvedSession;
use harness_session::types::{SessionLogEntry, SessionSignalRecord, SessionState};

use super::super::db::AsyncDaemonDb;
use super::super::protocol::{SessionDetail, SignalAckRequest, SignalCancelRequest};
use super::{sessions, sync_file_state_from_async_db};

impl AsyncSignalStorage for AsyncDaemonDb {
    async fn resolve_session(&self, session_id: &str) -> Result<Option<ResolvedSession>, CliError> {
        AsyncDaemonDb::resolve_session(self, session_id).await
    }

    async fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        AsyncDaemonDb::bump_change(self, scope).await
    }

    async fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        AsyncDaemonDb::sync_signal_index(self, session_id, records).await
    }

    async fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        AsyncDaemonDb::load_signals(self, session_id).await
    }

    async fn update_session_state_immediate<F, T>(
        &self,
        session_id: &str,
        update: F,
    ) -> Result<T, CliError>
    where
        F: FnOnce(&mut SessionState) -> Result<T, CliError> + Send,
        T: Send,
    {
        AsyncDaemonDb::update_session_state_immediate(self, session_id, update).await
    }

    async fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        AsyncDaemonDb::append_log_entry(self, entry).await
    }

    async fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        AsyncDaemonDb::save_session_state(self, project_id, state).await
    }

    async fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        AsyncDaemonDb::merge_signal_records(self, session_id, records).await
    }

    async fn session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        sessions::session_detail_from_async_daemon_db(session_id, self).await
    }

    async fn sync_file_state(&self, session_id: &str) -> Result<(), CliError> {
        sync_file_state_from_async_db(self, session_id).await
    }
}

pub(crate) async fn cancel_signal_async(
    session_id: &str,
    request: &SignalCancelRequest,
    db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::cancel_signal_async(session_id, request, db).await
}

pub(crate) async fn record_signal_ack_direct_async(
    session_id: &str,
    request: &SignalAckRequest,
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    harness_daemon_session_service::record_signal_ack_direct_async(session_id, request, db).await
}
