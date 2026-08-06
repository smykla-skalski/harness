use std::future::Future;

use harness_daemon_db_queries::AgentTuiLiveRefreshState;
use harness_kernel::errors::CliError;
use harness_protocol::managed_agents::tui::AgentTuiSnapshot;

/// Managed-terminal-agent persistence the manager needs on its async path,
/// independent of the concrete database type. The sync path reaches the
/// same data through `harness_daemon_db_queries::RuntimeSnapshotQueries`
/// directly - already `pub` there, so no port is needed for it. This one
/// exists because its async twin isn't: `harness-daemon` implements this for
/// its own async database handle, delegating to the SQL it already has.
pub trait AsyncAgentTuiStorage: Send + Sync {
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    fn save_agent_tui(
        &self,
        snapshot: &AgentTuiSnapshot,
    ) -> impl Future<Output = Result<(), CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn agent_tui(
        &self,
        tui_id: &str,
    ) -> impl Future<Output = Result<Option<AgentTuiSnapshot>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn agent_tui_live_refresh_state(
        &self,
        tui_id: &str,
    ) -> impl Future<Output = Result<Option<AgentTuiLiveRefreshState>, CliError>> + Send;

    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn list_agent_tuis(
        &self,
        session_id: &str,
    ) -> impl Future<Output = Result<Vec<AgentTuiSnapshot>, CliError>> + Send;
}
