use clap::Args;

use crate::app::command_context::{CommandContext, Execute, RunDirArgs, resolve_run_dir};
use crate::errors::CliError;
use crate::run::workflow::{
    RunnerEvent, apply_event, initialize_runner_state, read_runner_state,
};

impl Execute for RunnerStateArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        runner_state(
            self.event,
            self.suite_target.as_deref(),
            self.message.as_deref(),
            &self.run_dir,
        )
    }
}

/// Arguments for `harness runner-state`.
#[derive(Debug, Clone, Args)]
pub struct RunnerStateArgs {
    /// Workflow event to apply; omit to print the current phase.
    #[arg(long, value_enum)]
    pub event: Option<RunnerEvent>,
    /// Suite-relative manifest path for manifest-fix events.
    #[arg(long)]
    pub suite_target: Option<String>,
    /// Optional message to record on the event.
    #[arg(long)]
    pub message: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Manage runner workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn runner_state(
    event: Option<RunnerEvent>,
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
        let phase = serde_json::to_value(state.phase())
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| format!("{:?}", state.phase()).to_lowercase());
        println!("{phase}");
        return Ok(0);
    };

    let updated = apply_event(&run_dir, event_name, suite_target, message)?;
    let phase = serde_json::to_value(updated.phase())
        .ok()
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_else(|| format!("{:?}", updated.phase()).to_lowercase());
    println!("{phase}");
    Ok(0)
}
