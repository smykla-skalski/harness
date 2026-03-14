use std::fs;

use crate::authoring::authoring_workspace_dir;
use crate::errors::CliError;

/// Reset suite-author workspace.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute() -> Result<i32, CliError> {
    let workspace = authoring_workspace_dir();
    if workspace.exists() {
        fs::remove_dir_all(&workspace).map_err(|e| CliError {
            code: "IO".to_string(),
            message: format!("failed to remove workspace: {e}"),
            exit_code: 1,
            hint: None,
            details: None,
        })?;
    }
    Ok(0)
}
