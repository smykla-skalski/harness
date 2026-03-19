use clap::Args;

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::errors::CliError;
use crate::hooks::SessionStartHookOutput;
use crate::setup::services::session as session_service;

impl Execute for SessionStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        session_start(self.project_dir.as_deref())
    }
}

impl Execute for SessionStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        session_stop(self.project_dir.as_deref())
    }
}

/// Arguments for `harness session-start`.
#[derive(Debug, Clone, Args)]
pub struct SessionStartArgs {
    /// Project directory to restore session state for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

/// Arguments for `harness session-stop`.
#[derive(Debug, Clone, Args)]
pub struct SessionStopArgs {
    /// Project directory to clean up.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

/// Handle session start hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_start(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    session_service::bootstrap_project_wrapper(&dir);

    if let Some(context) = session_service::restore_compact_handoff(&dir)? {
        let output = SessionStartHookOutput::from_additional_context(&context);
        if let Ok(json) = output.to_json() {
            print!("{json}");
        }
        return Ok(0);
    }

    Ok(0)
}

/// Handle session stop cleanup.
///
/// Reads the current run pointer, cleans up ephemeral `MetalLB` templates
/// for that run, and removes the pointer file. All steps degrade
/// gracefully - a missing or stale pointer is not an error.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_stop(_project_dir: Option<&str>) -> Result<i32, CliError> {
    session_service::cleanup_current_run_context()?;
    Ok(0)
}
