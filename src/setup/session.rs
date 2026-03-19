use std::env;

use clap::Args;

use tracing::warn;

use crate::app::command_context::{AppContext, Execute, resolve_project_dir};
use crate::workspace::compact;
use crate::errors::CliError;
use crate::hooks::session::SessionStartHookOutput;
use crate::platform::ephemeral_metallb;
use crate::run::context::RunRepository;
use crate::setup::wrapper;

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

    // Bootstrap the project wrapper
    let path_env = env::var("PATH").unwrap_or_default();
    if let Err(e) = wrapper::main(&dir, &path_env) {
        warn!(%e, "bootstrap failed");
    }

    // Check for a pending compact handoff to restore
    let handoff = compact::pending_compact_handoff(&dir)?;
    if let Some(h) = handoff {
        let diverged = compact::verify_fingerprints(&h);
        let context = compact::render_hydration_context(&h, &diverged);
        if let Err(e) = compact::consume_compact_handoff(&dir, h) {
            warn!(%e, "compact handoff consume failed");
        }
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
    let repo = RunRepository;
    let Some(record) = repo.load_current_pointer()? else {
        return Ok(0);
    };

    let run_dir = record.layout.run_dir();
    if run_dir.is_dir()
        && let Err(e) = ephemeral_metallb::cleanup_templates(&run_dir)
    {
        warn!(%e, "cleanup templates failed");
    }

    if let Err(e) = repo.clear_current_pointer() {
        warn!(%e, "failed to remove run pointer");
    }
    Ok(0)
}
