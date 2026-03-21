use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for LogsArgs {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        logs(context, &self.name, self.tail, self.follow, &self.run_dir)
    }
}

/// Arguments for `harness logs`.
#[derive(Debug, Clone, Args)]
pub struct LogsArgs {
    /// Container or member name.
    pub name: String,
    /// Number of log lines to show.
    #[arg(long, default_value = "100")]
    pub tail: u32,
    /// Follow log output.
    #[arg(long)]
    pub follow: bool,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Show container logs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn logs(
    _ctx: &AppContext,
    name: &str,
    tail: u32,
    follow: bool,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run = resolve_run_application(run_dir_args)?;
    if let Some(result) = run.service_logs(name, tail, follow)? {
        print!("{}", result.stdout);
        if !result.stderr.is_empty() {
            eprint!("{}", result.stderr);
        }
    }
    Ok(0)
}

#[cfg(test)]
#[path = "logs/tests.rs"]
mod tests;
