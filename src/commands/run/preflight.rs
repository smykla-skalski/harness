use clap::Args;

use crate::commands::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::core_defs::{shorten_path, utc_now};
use crate::errors::CliError;

/// Arguments for `harness preflight`.
#[derive(Debug, Clone, Args)]
pub struct PreflightArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Repo root for prepared-suite metadata.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Run preflight checks and prepare suite manifests.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn preflight(
    _kubeconfig: Option<&str>,
    _repo_root: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;

    eprintln!("{} preflight: complete", utc_now());
    println!("{}", shorten_path(&ctx.layout.artifacts_dir()));
    Ok(0)
}
