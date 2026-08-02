use harness_daemon_session_service::AsyncSignalStorage;
use harness_kernel::errors::CliError;
use harness_session::index::ResolvedSession;
use harness_session::types::{SessionLogEntry, SessionSignalRecord, SessionState};

use super::super::db::AsyncDaemonDb;
use super::super::db::prelude::*;
use super::super::protocol::{SessionDetail, SignalAckRequest, SignalCancelRequest};
use super::{sessions, sync_file_state_from_async_db};

impl AsyncSignalStorage for AsyncDaemonDb {
    async fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError> {
        <Self as AsyncSessionStateQueries>::load_session_state(self, session_id).await
    }

    async fn resolve_session(&self, session_id: &str) -> Result<Option<ResolvedSession>, CliError> {
        AsyncDaemonDb::resolve_session(self, session_id).await
    }

    async fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        <Self as AsyncSessionWriteQueries>::bump_change(self, scope).await
    }

    async fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        <Self as AsyncSignalIndexQueries>::sync_signal_index(self, session_id, records).await
    }

    async fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        <Self as AsyncSignalReadQueries>::load_signals(self, session_id).await
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
        <Self as AsyncSessionStateQueries>::update_session_state_immediate(
            self, session_id, update,
        )
        .await
    }

    async fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        <Self as AsyncSessionWriteQueries>::append_log_entry(self, entry).await
    }

    async fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        <Self as AsyncSessionWriteQueries>::save_session_state(self, project_id, state).await
    }

    async fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        <Self as AsyncSignalIndexQueries>::merge_signal_records(self, session_id, records).await
    }

    async fn session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        sessions::session_detail_from_async_daemon_db(session_id, self).await
    }

    async fn sync_file_state(&self, session_id: &str) -> Result<(), CliError> {
        sync_file_state_from_async_db(self, session_id).await
    }

    async fn load_expired_pending_signals(
        &self,
        session_id: &str,
    ) -> Result<Vec<harness_daemon_session_service::ExpiredPendingSignalIndexRecord>, CliError>
    {
        <Self as AsyncSignalReadQueries>::load_expired_pending_signals(self, session_id).await
    }

    async fn list_project_summaries(
        &self,
    ) -> Result<Vec<harness_session::wire::ProjectSummary>, CliError> {
        AsyncDaemonDb::list_project_summaries(self).await
    }

    async fn list_session_summaries(
        &self,
    ) -> Result<Vec<harness_session::wire::SessionSummary>, CliError> {
        AsyncDaemonDb::list_session_summaries(self).await
    }

    async fn resolve_runtime_session_agents(
        &self,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Vec<(String, String)>, CliError> {
        <Self as AsyncAgentResolutionQueries>::resolve_runtime_session_agents(
            self,
            runtime_name,
            runtime_session_id,
        )
        .await
    }

    async fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<harness_session::wire::AgentToolActivitySummary>, CliError> {
        <Self as AsyncSignalReadQueries>::load_agent_activity(self, session_id).await
    }

    async fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &harness_protocol::timeline::TimelineWindowRequest,
    ) -> Result<Option<harness_protocol::timeline::TimelineWindowResponse>, CliError> {
        <Self as AsyncTimelineWindowQueries>::load_session_timeline_window(
            self, session_id, request,
        )
        .await
    }

    async fn load_session_acp_transcript_entries(
        &self,
        session_id: &str,
    ) -> Result<Vec<harness_protocol::timeline::TimelineEntry>, CliError> {
        <Self as AsyncTimelineWindowQueries>::load_session_acp_transcript_entries(
            self, session_id,
        )
        .await
    }

    async fn list_liveness_candidate_ids(&self) -> Result<Vec<String>, CliError> {
        AsyncDaemonDb::list_liveness_candidate_ids(self).await
    }

    async fn sync_project(
        &self,
        project: &harness_session::index::DiscoveredProject,
    ) -> Result<(), CliError> {
        <Self as AsyncSessionWriteQueries>::sync_project(self, project).await
    }

    async fn create_session_record(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        <Self as AsyncSessionWriteQueries>::create_session_record(self, project_id, state).await
    }

    async fn delete_session_row(&self, session_id: &str) -> Result<bool, CliError> {
        <Self as AsyncSessionWriteQueries>::delete_session_row(self, session_id).await
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
