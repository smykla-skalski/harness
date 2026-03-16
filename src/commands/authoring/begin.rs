use std::path::Path;

use crate::authoring::begin_authoring_session;
use crate::errors::CliError;

// =========================================================================
// begin
// =========================================================================

/// Begin a suite:new workspace session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin(
    repo_root: &str,
    feature: &str,
    mode: &str,
    suite_dir: &str,
    suite_name: &str,
) -> Result<i32, CliError> {
    begin_authoring_session(
        Path::new(repo_root),
        feature,
        mode,
        Path::new(suite_dir),
        suite_name,
    )?;
    Ok(0)
}
