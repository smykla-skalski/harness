use harness_daemon_session_service::AsyncSignalStorage;
use harness_kernel::errors::CliError;
use harness_session::index::ResolvedSession;
use harness_session::types::{SessionLogEntry, SessionSignalRecord, SessionState};

use super::super::db::AsyncDaemonDb;
use super::super::db::prelude::*;
use super::super::protocol::{SessionDetail, SignalAckRequest, SignalCancelRequest};
use super::{sessions, sync_file_state_from_async_db};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

impl AsyncSignalStorage for AsyncDaemonDbHandle {
    async fn load_session_state(&self, session_id: &str) -> Result<Option<SessionState>, CliError> {
        <AsyncDaemonDb as AsyncSessionStateQueries>::load_session_state(&self.0, session_id).await
    }

    async fn resolve_session(&self, session_id: &str) -> Result<Option<ResolvedSession>, CliError> {
        <AsyncDaemonDb as AsyncSessionSummaryQueries>::resolve_session(&self.0, session_id).await
    }

    async fn bump_change(&self, scope: &str) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::bump_change(&self.0, scope).await
    }

    async fn sync_signal_index(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSignalIndexQueries>::sync_signal_index(&self.0, session_id, records)
            .await
    }

    async fn load_signals(&self, session_id: &str) -> Result<Vec<SessionSignalRecord>, CliError> {
        <AsyncDaemonDb as AsyncSignalReadQueries>::load_signals(&self.0, session_id).await
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
        <AsyncDaemonDb as AsyncSessionStateQueries>::update_session_state_immediate(
            &self.0, session_id, update,
        )
        .await
    }

    async fn append_log_entry(&self, entry: &SessionLogEntry) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::append_log_entry(&self.0, entry).await
    }

    async fn save_session_state(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::save_session_state(&self.0, project_id, state)
            .await
    }

    async fn merge_signal_records(
        &self,
        session_id: &str,
        records: &[SessionSignalRecord],
    ) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSignalIndexQueries>::merge_signal_records(
            &self.0, session_id, records,
        )
        .await
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
        <AsyncDaemonDb as AsyncSignalReadQueries>::load_expired_pending_signals(&self.0, session_id)
            .await
    }

    async fn list_project_summaries(
        &self,
    ) -> Result<Vec<harness_session::wire::ProjectSummary>, CliError> {
        AsyncDaemonDb::list_project_summaries(&self.0).await
    }

    async fn list_session_summaries(
        &self,
    ) -> Result<Vec<harness_session::wire::SessionSummary>, CliError> {
        <AsyncDaemonDb as AsyncSessionSummaryQueries>::list_session_summaries(&self.0).await
    }

    async fn resolve_runtime_session_agents(
        &self,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<Vec<(String, String)>, CliError> {
        <AsyncDaemonDb as AsyncAgentResolutionQueries>::resolve_runtime_session_agents(
            &self.0,
            runtime_name,
            runtime_session_id,
        )
        .await
    }

    async fn load_agent_activity(
        &self,
        session_id: &str,
    ) -> Result<Vec<harness_session::wire::AgentToolActivitySummary>, CliError> {
        <AsyncDaemonDb as AsyncSignalReadQueries>::load_agent_activity(&self.0, session_id).await
    }

    async fn load_session_timeline_window(
        &self,
        session_id: &str,
        request: &harness_protocol::timeline::TimelineWindowRequest,
    ) -> Result<Option<harness_protocol::timeline::TimelineWindowResponse>, CliError> {
        <AsyncDaemonDb as AsyncTimelineWindowQueries>::load_session_timeline_window(
            &self.0, session_id, request,
        )
        .await
    }

    async fn load_session_acp_transcript_entries(
        &self,
        session_id: &str,
    ) -> Result<Vec<harness_protocol::timeline::TimelineEntry>, CliError> {
        <AsyncDaemonDb as AsyncTimelineWindowQueries>::load_session_acp_transcript_entries(
            &self.0, session_id,
        )
        .await
    }

    async fn list_liveness_candidate_ids(&self) -> Result<Vec<String>, CliError> {
        AsyncDaemonDb::list_liveness_candidate_ids(&self.0).await
    }

    async fn sync_project(
        &self,
        project: &harness_session::index::DiscoveredProject,
    ) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::sync_project(&self.0, project).await
    }

    async fn create_session_record(
        &self,
        project_id: &str,
        state: &SessionState,
    ) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::create_session_record(
            &self.0, project_id, state,
        )
        .await
    }

    async fn delete_session_row(&self, session_id: &str) -> Result<bool, CliError> {
        <AsyncDaemonDb as AsyncSessionWriteQueries>::delete_session_row(&self.0, session_id).await
    }
}

pub(crate) async fn cancel_signal_async(
    session_id: &str,
    request: &SignalCancelRequest,
    db: &AsyncDaemonDbHandle,
) -> Result<SessionDetail, CliError> {
    harness_daemon_session_service::cancel_signal_async(session_id, request, db).await
}

pub(crate) async fn record_signal_ack_direct_async(
    session_id: &str,
    request: &SignalAckRequest,
    db: &AsyncDaemonDbHandle,
) -> Result<(), CliError> {
    if super::agent_workspace_activity::record_native_runtime_acknowledgment_from_session_route(
        db,
        session_id,
        &request.agent_id,
        &request.signal_id,
    )
    .await?
    {
        return Ok(());
    }
    harness_daemon_session_service::record_signal_ack_direct_async(session_id, request, db).await
}
