use clap::Args;

use tracing::info;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::args::RunDirArgs;
use crate::workspace::{shorten_path, utc_now};

use super::shared::resolve_run_application_with_blocks;

impl Execute for PreflightArgs {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        preflight(
            context,
            self.kubeconfig.as_deref(),
            self.repo_root.as_deref(),
            &self.run_dir,
        )
    }
}

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
    ctx: &AppContext,
    _kubeconfig: Option<&str>,
    _repo_root: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let checked_at = utc_now();
    let run = resolve_run_application_with_blocks(run_dir_args, ctx.shared_blocks())?;
    run.validate_requirement_names()?;
    let _ = run.save_preflight_outputs(&checked_at)?;
    run.record_preflight_complete()?;

    info!("preflight complete");
    println!("{}", shorten_path(&run.layout().artifacts_dir()));
    Ok(0)
}
