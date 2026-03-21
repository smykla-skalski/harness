use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::create::application::CreateApplication;
use crate::errors::CliError;

impl Execute for CreateResetArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        reset()
    }
}

/// Arguments for `harness create-reset`.
#[derive(Debug, Clone, Args)]
pub struct CreateResetArgs {
    /// Managed skill whose saved workspace should be cleared.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new([crate::kernel::skills::SKILL_CREATE]))]
    pub skill: String,
}

/// Reset suite:create workspace.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn reset() -> Result<i32, CliError> {
    CreateApplication::reset_workspace()?;
    Ok(0)
}
