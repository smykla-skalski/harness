use harness_kernel::errors::CliError;
use harness_task_board::policy_graph::PolicyCanvasWorkspace;

/// Whether task-board automation's spawn kill switch is engaged - the
/// manager checks this before starting a new terminal agent. `harness-daemon`
/// implements this for its own database handle, delegating to the policy
/// workspace it already loads for task-board automation.
pub trait AgentTuiKillSwitch {
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError>;
}
