use std::fs;

use crate::authoring::authoring_workspace_dir;
use crate::errors::CliError;

/// Reset suite:new workspace.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn reset() -> Result<i32, CliError> {
    let workspace = authoring_workspace_dir()?;
    if workspace.exists() {
        fs::remove_dir_all(&workspace)?;
    }
    Ok(0)
}
