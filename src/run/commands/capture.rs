use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::infra::io::validate_safe_segment;
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for CaptureArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        capture(self.kubeconfig.as_deref(), &self.label, &self.run_dir)
    }
}

/// Arguments for `harness capture`.
#[derive(Debug, Clone, Args)]
pub struct CaptureArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Label for the saved artifact filename.
    #[arg(long)]
    pub label: String,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Capture cluster pod state for a run.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capture(
    kubeconfig: Option<&str>,
    label: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    validate_safe_segment(label)?;
    let mut run = resolve_run_application(run_dir_args)?;
    let rel = run.capture_state(label, kubeconfig)?;
    println!("{rel}");
    Ok(0)
}
