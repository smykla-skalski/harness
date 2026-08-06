use harness_daemon_db_queries::AgentTuiLiveRefreshState;
use harness_daemon_managed_agents::AsyncAgentTuiStorage;
use harness_kernel::errors::CliError;
use harness_protocol::managed_agents::tui::AgentTuiSnapshot;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::AsyncRuntimeSnapshotQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

impl AsyncAgentTuiStorage for AsyncDaemonDbHandle {
    async fn save_agent_tui(&self, snapshot: &AgentTuiSnapshot) -> Result<(), CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::save_agent_tui(&self.0, snapshot).await
    }

    async fn agent_tui(&self, tui_id: &str) -> Result<Option<AgentTuiSnapshot>, CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::agent_tui(&self.0, tui_id).await
    }

    async fn agent_tui_live_refresh_state(
        &self,
        tui_id: &str,
    ) -> Result<Option<AgentTuiLiveRefreshState>, CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::agent_tui_live_refresh_state(
            &self.0, tui_id,
        )
        .await
    }

    async fn list_agent_tuis(&self, session_id: &str) -> Result<Vec<AgentTuiSnapshot>, CliError> {
        <AsyncDaemonDb as AsyncRuntimeSnapshotQueries>::list_agent_tuis(&self.0, session_id).await
    }
}
