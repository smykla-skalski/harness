use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::errors::CliError;
use crate::resolve::resolve_run_directory;

fn resolve_run_dir(run_dir_args: &RunDirArgs) -> Result<PathBuf, CliError> {
    let lookup = crate::context::RunLookup {
        run_dir: run_dir_args.run_dir.clone(),
        run_id: run_dir_args.run_id.clone(),
        run_root: run_dir_args.run_root.clone(),
    };
    Ok(resolve_run_directory(&lookup)?.run_dir)
}

/// Run preflight checks and prepare suite manifests.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    _kubeconfig: Option<&str>,
    _repo_root: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;

    eprintln!("{} preflight: complete", crate::core_defs::utc_now());
    println!("{}", ctx.layout.artifacts_dir().display());
    Ok(0)
}
