use crate::cli::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::schema::Verdict;

/// Close out a run by verifying required artifacts.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn closeout(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let run_dir = ctx.layout.run_dir();

    let required = [
        "commands/command-log.md",
        "manifests/manifest-index.md",
        "run-report.md",
        "run-status.json",
    ];

    for rel in &required {
        if !run_dir.join(rel).exists() {
            return Err(CliErrorKind::missing_closeout_artifact(*rel).into());
        }
    }

    let status = ctx
        .status
        .as_ref()
        .ok_or_else(|| -> CliError { CliErrorKind::MissingRunStatus.into() })?;
    if status.last_state_capture.is_none() {
        return Err(CliErrorKind::MissingStateCapture.into());
    }
    if status.overall_verdict == Verdict::Pending {
        return Err(CliErrorKind::VerdictPending.into());
    }

    println!("run closeout is complete; start a new run id for any further bootstrap or execution");
    Ok(0)
}
