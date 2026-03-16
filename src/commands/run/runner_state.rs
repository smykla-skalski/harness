use crate::cli::RunDirArgs;
use crate::commands::resolve_run_dir;
use crate::errors::{CliError, CliErrorKind};
use crate::workflow::runner::{initialize_runner_state, read_runner_state};

/// Manage runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn runner_state(
    event: Option<&str>,
    _suite_target: Option<&str>,
    _message: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;

    let state = match read_runner_state(&run_dir)? {
        Some(s) => s,
        None => initialize_runner_state(&run_dir)?,
    };

    if event.is_none() {
        let phase = serde_json::to_value(state.phase)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| format!("{:?}", state.phase).to_lowercase());
        println!("{phase}");
        return Ok(0);
    }

    Err(CliErrorKind::usage_error(
        "event-based transitions are handled by the workflow module's \
         request_* functions; this CLI path only supports state queries",
    )
    .into())
}
