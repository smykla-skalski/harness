use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::application::RunApplication;
use crate::run::args::RunDirArgs;
use crate::workspace::shorten_path;

impl Execute for ResumeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        resume(&self.run_dir, self.message.as_deref())
    }
}

/// Arguments for `harness run resume`.
#[derive(Debug, Clone, Args)]
pub struct ResumeArgs {
    /// Optional workflow note recorded when a suspended or aborted run resumes.
    #[arg(long)]
    pub message: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Reattach or resume an unfinished run.
///
/// # Errors
/// Returns `CliError` when the run cannot be resolved or is already finalized.
pub fn resume(run_dir_args: &RunDirArgs, message: Option<&str>) -> Result<i32, CliError> {
    let result = RunApplication::resume(run_dir_args, message)?;
    println!("{}", shorten_path(&result.run_dir));
    println!("phase: {}", result.phase);
    if result.resumed {
        println!("status: resumed");
    } else {
        println!("status: attached");
    }
    println!("next: {}", result.next_action);
    Ok(0)
}
