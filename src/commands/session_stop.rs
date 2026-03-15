use std::fs;

use crate::context::CurrentRunRecord;
use crate::core_defs::current_run_context_path;
use crate::ephemeral_metallb;
use crate::errors::CliError;

/// Handle session stop cleanup.
///
/// Reads the current run pointer, cleans up ephemeral `MetalLB` templates
/// for that run, and removes the pointer file. All steps degrade
/// gracefully - a missing or stale pointer is not an error.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(_project_dir: Option<&str>) -> Result<i32, CliError> {
    let ctx_path = current_run_context_path();
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
