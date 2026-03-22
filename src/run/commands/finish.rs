use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::RunApplication;
use crate::run::args::RunDirArgs;
use crate::run::commands::shared::resolve_run_application;
use crate::workspace::shorten_path;

impl Execute for FinishArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        finish(&self.run_dir)
    }
}

/// Arguments for `harness run finish`.
#[derive(Debug, Clone, Args)]
pub struct FinishArgs {
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Finish a run by closing it out and validating the report.
///
/// # Errors
/// Returns `CliError` when the run cannot be resolved, closeout fails, or the
/// report does not pass compactness checks.
pub fn finish(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let run = resolve_run_application(run_dir_args)?;
    let result = RunApplication::finish(&run)?;
    println!("{}", shorten_path(&result.report_path));
    Ok(0)
}
