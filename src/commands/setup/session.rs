use std::env;
use std::fs;

use crate::bootstrap;
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
    let dir = crate::commands::resolve_project_dir(project_dir);

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
        let _ = fs::remove_file(&ctx_path);
        return Ok(0);
    };

    let run_dir = record.layout.run_dir();
    if run_dir.is_dir() {
        let _ = ephemeral_metallb::cleanup_templates(&run_dir);
    }

    let _ = fs::remove_file(&ctx_path);
    Ok(0)
}
