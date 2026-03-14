use std::path::PathBuf;

use crate::errors::CliError;

/// Handle session start hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = project_dir
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    // Bootstrap the project wrapper
    let path_env = std::env::var("PATH").unwrap_or_default();
    let _ = crate::bootstrap::main(&dir, &path_env);

    // Check for a pending compact handoff to restore
    let handoff = crate::compact::pending_compact_handoff(&dir);
    if let Some(ref h) = handoff {
        let diverged = crate::compact::verify_fingerprints(h);
        let context = crate::compact::render_hydration_context(h, &diverged);
        let _ = crate::compact::consume_compact_handoff(&dir, h);
        let output = crate::session_hook::SessionStartHookOutput::from_additional_context(&context);
        if let Ok(json) = output.to_json() {
            print!("{json}");
        }
        return Ok(0);
    }

    Ok(0)
}
