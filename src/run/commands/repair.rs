use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::application;
use crate::run::args::RunDirArgs;

use super::doctor::render_report;

impl Execute for RepairArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        repair(&self.run_dir, self.json)
    }
}

/// Arguments for `harness run repair`.
#[derive(Debug, Clone, Args)]
pub struct RepairArgs {
    /// Output machine-readable JSON.
    #[arg(long)]
    pub json: bool,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Repair deterministic run state and the current pointer.
///
/// # Errors
/// Returns `CliError` on operational failures.
pub fn repair(run_dir_args: &RunDirArgs, json: bool) -> Result<i32, CliError> {
    let report = application::repair(run_dir_args)?;
    render_report(&report, json);
    Ok(if report.ok { 0 } else { 2 })
}
