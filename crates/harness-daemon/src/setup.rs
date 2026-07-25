pub mod wrapper {
    use std::path::{Path, PathBuf};

    use harness_protocol::agent::HookAgent;

    use harness_kernel::errors::{CliError, CliErrorKind};

    /// Run the standalone hook setup wrapper with an explicit home directory.
    ///
    /// # Errors
    ///
    /// Returns an error when standalone hook setup fails.
    pub fn main_with_home(
        project_dir: &Path,
        path_env: &str,
        home: &Path,
    ) -> Result<i32, CliError> {
        harness_hook::setup::wrapper::main_with_home(project_dir, path_env, home)
            .map_err(|error| map_hook_error(&error))
    }

    /// Write the agent bootstrap files for the selected runtime hooks.
    ///
    /// # Errors
    ///
    /// Returns an error when standalone hook setup fails.
    pub fn write_agent_bootstrap(
        project_dir: &Path,
        agent: HookAgent,
        skip_runtime_hooks: &[HookAgent],
    ) -> Result<Vec<PathBuf>, CliError> {
        harness_hook::setup::wrapper::write_agent_bootstrap(project_dir, agent, skip_runtime_hooks)
            .map_err(|error| map_hook_error(&error))
    }

    fn map_hook_error(error: &harness_kernel::errors::CliError) -> CliError {
        CliErrorKind::workflow_io(format!("standalone hook setup failed: {error}")).into()
    }
}
