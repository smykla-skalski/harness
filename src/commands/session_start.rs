use std::env;
use std::path::PathBuf;

use crate::bootstrap;
use crate::compact;
use crate::errors::CliError;
use crate::session_hook::SessionStartHookOutput;

/// Handle session start hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = project_dir.filter(|s| !s.is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        PathBuf::from,
    );

    // Bootstrap the project wrapper
    let path_env = env::var("PATH").unwrap_or_default();
    if let Err(e) = bootstrap::main(&dir, &path_env) {
        eprintln!("warning: bootstrap failed: {e}");
    }

    // Check for a pending compact handoff to restore
    let handoff = compact::pending_compact_handoff(&dir);
    if let Some(h) = handoff {
        let diverged = compact::verify_fingerprints(&h);
        let context = compact::render_hydration_context(&h, &diverged);
        if let Err(e) = compact::consume_compact_handoff(&dir, h) {
            eprintln!("warning: compact handoff consume failed: {e}");
        }
        let output = SessionStartHookOutput::from_additional_context(&context);
        if let Ok(json) = output.to_json() {
            print!("{json}");
        }
        return Ok(0);
    }

    Ok(0)
}
