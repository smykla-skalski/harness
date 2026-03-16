use clap::Args;

use crate::commands::RunDirArgs;
use crate::commands::resolve_run_services;
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
    let checked_at = utc_now();
    let services = resolve_run_services(run_dir_args)?;
    let _ = services.save_preflight_outputs(&checked_at)?;
    services.record_preflight_complete()?;

    eprintln!("{checked_at} preflight: complete");
    println!("{}", shorten_path(&services.layout().artifacts_dir()));
    Ok(0)
}
