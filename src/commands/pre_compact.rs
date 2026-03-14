use std::path::PathBuf;

use crate::compact::{build_compact_handoff, save_compact_handoff};
use crate::errors::CliError;

/// Save compact handoff before compaction.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = project_dir
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    let handoff = build_compact_handoff(&dir)?;
    save_compact_handoff(&dir, &handoff)?;
    Ok(0)
}
