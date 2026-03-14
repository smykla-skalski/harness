use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::errors::{self, CliError};

/// Close out a run by verifying required artifacts.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;
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

    let status = ctx
        .status
        .as_ref()
        .ok_or_else(|| errors::cli_err(&errors::MISSING_RUN_STATUS, &[]))?;
    if status.last_state_capture.is_none() {
        return Err(errors::cli_err(&errors::MISSING_STATE_CAPTURE, &[]));
    }
    if status.overall_verdict == "pending" {
        return Err(errors::cli_err(&errors::VERDICT_PENDING, &[]));
    }

    println!("run closeout is complete; start a new run id for any further bootstrap or execution");
    Ok(0)
}
