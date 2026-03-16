use crate::cli::RunDirArgs;
use crate::commands::resolve_run_dir;
use crate::errors::CliError;
use crate::workflow::runner::{apply_event, initialize_runner_state, read_runner_state};

/// Manage runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn runner_state(
    event: Option<&str>,
    suite_target: Option<&str>,
    message: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;

    let state = match read_runner_state(&run_dir)? {
        Some(s) => s,
        None => initialize_runner_state(&run_dir)?,
    };

    let Some(event_name) = event else {
        let phase = serde_json::to_value(state.phase)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| format!("{:?}", state.phase).to_lowercase());
        println!("{phase}");
        return Ok(0);
    };

    let updated = apply_event(&run_dir, event_name, suite_target, message)?;
    let phase = serde_json::to_value(updated.phase)
        .ok()
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_else(|| format!("{:?}", updated.phase).to_lowercase());
    println!("{phase}");
    Ok(0)
}
