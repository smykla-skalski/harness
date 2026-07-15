use clap::Args;

use crate::app::resolve_project_dir;
use crate::errors::CliError;
use crate::workspace::compact::{build_compact_handoff, save_compact_handoff};

#[path = "../../../src/setup/wrapper/mod.rs"]
pub mod wrapper;

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
    let directory = resolve_project_dir(project_dir);
    let handoff = build_compact_handoff(&directory)?;
    save_compact_handoff(&directory, &handoff)?;
    Ok(0)
}
