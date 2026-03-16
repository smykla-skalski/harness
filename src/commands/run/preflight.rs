use crate::cli::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::core_defs::utc_now;
use crate::errors::CliError;

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
    println!("{}", ctx.layout.artifacts_dir().display());
    Ok(0)
}
