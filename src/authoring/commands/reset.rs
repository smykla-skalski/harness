use std::fs;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::authoring_workspace_dir;
use crate::errors::CliError;

impl Execute for AuthoringResetArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        reset()
    }
}

/// Arguments for `harness authoring-reset`.
#[derive(Debug, Clone, Args)]
pub struct AuthoringResetArgs {
    /// Managed skill whose saved workspace should be cleared.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new([crate::kernel::skills::SKILL_NEW]))]
    pub skill: String,
}

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
