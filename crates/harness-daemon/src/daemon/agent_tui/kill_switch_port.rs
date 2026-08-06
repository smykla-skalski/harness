use harness_daemon_managed_agents::AgentTuiKillSwitch;
use harness_kernel::errors::CliError;
use harness_task_board::policy_graph::PolicyCanvasWorkspace;

use crate::daemon::db::DaemonDb;
use crate::daemon::db_handle::DaemonDbOwnedHandle;
use crate::daemon::reviews_store::PolicyGraphSyncQueries;

impl AgentTuiKillSwitch for DaemonDbOwnedHandle {
    fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
        <DaemonDb as PolicyGraphSyncQueries>::load_policy_workspace(&self.0)
    }
}
