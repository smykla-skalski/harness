use clap::Args;

use crate::app::command_context::{CommandContext, Execute, RunDirArgs, resolve_run_services};
use crate::errors::{CliError, CliErrorKind};

impl Execute for StatusArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        status(&self.run_dir)
    }
}

/// Arguments for `harness status`.
#[derive(Debug, Clone, Args)]
pub struct StatusArgs {
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Show cluster state as structured JSON.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn status(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let services = resolve_run_services(run_dir_args)?;
    let output = services.status_report()?;
    let pretty = serde_json::to_string_pretty(&output)
        .map_err(|e| CliErrorKind::serialize(format!("status: {e}")))?;
    println!("{pretty}");
    Ok(0)
}
