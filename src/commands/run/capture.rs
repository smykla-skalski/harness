use clap::Args;

use crate::commands::{RunDirArgs, resolve_run_services};
use crate::errors::CliError;
use crate::io::validate_safe_segment;

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
    let services = resolve_run_services(run_dir_args)?;
    let rel = services.capture_state(label, kubeconfig)?;
    println!("{rel}");
    Ok(0)
}
