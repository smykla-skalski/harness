use clap::Args;

use crate::commands::resolve_project_dir;
use crate::compact::{build_compact_handoff, save_compact_handoff};
use crate::errors::CliError;

/// Arguments for `harness pre-compact`.
#[derive(Debug, Clone, Args)]
pub struct PreCompactArgs {
    /// Project directory to save the compact handoff for.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

/// Save compact handoff before compaction.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn pre_compact(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = resolve_project_dir(project_dir);
    let handoff = build_compact_handoff(&dir)?;
    save_compact_handoff(&dir, &handoff)?;
    Ok(0)
}
