use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::errors::{self, CliError};
use crate::resolve::resolve_run_directory;

fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    let lookup = crate::context::RunLookup {
        run_dir: args.run_dir.clone(),
        run_id: args.run_id.clone(),
        run_root: args.run_root.clone(),
    };
    Ok(resolve_run_directory(&lookup)?.run_dir)
}

/// Close out a run by verifying required artifacts.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;

    let required = [
        "commands/command-log.md",
        "manifests/manifest-index.md",
        "run-report.md",
        "run-status.json",
    ];

    for rel in &required {
        if !run_dir.join(rel).exists() {
            return Err(errors::cli_err(
                &errors::MISSING_CLOSEOUT_ARTIFACT,
                &[("rel", rel)],
            ));
        }
    }

    let status = ctx.status.as_ref();
    if let Some(s) = status {
        if s.last_state_capture.is_none() {
            return Err(errors::cli_err(&errors::MISSING_STATE_CAPTURE, &[]));
        }
        if s.overall_verdict == "pending" {
            return Err(errors::cli_err(&errors::VERDICT_PENDING, &[]));
        }
    }

    println!("run closeout is complete; start a new run id for any further bootstrap or execution");
    Ok(0)
}
