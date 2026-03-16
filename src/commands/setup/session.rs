use std::env;
use std::fs;

use crate::bootstrap;
use crate::commands::resolve_project_dir;
use crate::compact;
use crate::context::CurrentRunRecord;
use crate::core_defs::current_run_context_path;
use crate::ephemeral_metallb;
use crate::errors::CliError;
use crate::session_hook::SessionStartHookOutput;

/// Handle session start hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_start(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);

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

/// Handle session stop cleanup.
///
/// Reads the current run pointer, cleans up ephemeral `MetalLB` templates
/// for that run, and removes the pointer file. All steps degrade
/// gracefully - a missing or stale pointer is not an error.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_stop(_project_dir: Option<&str>) -> Result<i32, CliError> {
    let ctx_path = current_run_context_path()?;
    let Ok(text) = fs::read_to_string(&ctx_path) else {
        return Ok(0);
    };
    let Ok(record) = serde_json::from_str::<CurrentRunRecord>(&text) else {
        eprintln!("warning: corrupt run pointer JSON, removing");
        if let Err(e) = fs::remove_file(&ctx_path) {
            eprintln!("warning: failed to remove corrupt pointer: {e}");
        }
        return Ok(0);
    };

    let run_dir = record.layout.run_dir();
    if run_dir.is_dir()
        && let Err(e) = ephemeral_metallb::cleanup_templates(&run_dir)
    {
        eprintln!("warning: cleanup templates failed: {e}");
    }

    if let Err(e) = fs::remove_file(&ctx_path) {
        eprintln!("warning: failed to remove run pointer: {e}");
    }
    Ok(0)
}
