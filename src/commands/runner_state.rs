use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::errors::CliError;
use crate::resolve::resolve_run_directory;
use crate::workflow::runner::{initialize_runner_state, read_runner_state};

fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    let lookup = crate::context::RunLookup {
        run_dir: args.run_dir.clone(),
        run_id: args.run_id.clone(),
        run_root: args.run_root.clone(),
    };
    Ok(resolve_run_directory(&lookup)?.run_dir)
}

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

    // For now, just acknowledge the event. Full state machine transitions
    // are handled by the workflow module's request_* functions.
    let event_name = event.unwrap_or("unknown");
    eprintln!("runner-state: applied event {event_name}");
    Ok(0)
}
