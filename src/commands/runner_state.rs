use crate::cli::RunDirArgs;
use crate::errors::CliError;
use crate::workflow::runner::{initialize_runner_state, read_runner_state};

/// Manage runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    event: Option<&str>,
    _suite_target: Option<&str>,
    _message: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;

    let state = match read_runner_state(&run_dir)? {
        Some(s) => s,
        None => initialize_runner_state(&run_dir)?,
    };

    if event.is_none() {
        println!("{}", state.phase.name());
        return Ok(0);
    }

    // For now, just acknowledge the event. Full state machine transitions
    // are handled by the workflow module's request_* functions.
    let event_name = event.unwrap_or("unknown");
    eprintln!("runner-state: applied event {event_name}");
    Ok(0)
}
