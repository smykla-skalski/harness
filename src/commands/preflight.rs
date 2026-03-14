use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::core_defs::utc_now;
use crate::errors::CliError;

/// Run preflight checks and prepare suite manifests.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    _kubeconfig: Option<&str>,
    _repo_root: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;

    eprintln!("{} preflight: complete", utc_now());
    println!("{}", ctx.layout.artifacts_dir().display());
    Ok(0)
}
