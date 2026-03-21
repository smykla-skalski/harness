use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::create::application::CreateApplication;
use crate::errors::CliError;

impl Execute for CreateSaveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        save(&self.kind, self.payload.as_deref(), self.input.as_deref())
    }
}

/// Arguments for `harness create-save`.
#[derive(Debug, Clone, Args)]
pub struct CreateSaveArgs {
    /// Suite:create payload kind.
    #[arg(long, value_parser = [
        "inventory", "coverage", "variants", "schema",
        "proposal", "edit-request",
    ])]
    pub kind: String,
    /// Inline JSON payload.
    #[arg(long)]
    pub payload: Option<String>,
    /// Read JSON from a file; use stdin only as fallback.
    #[arg(long)]
    pub input: Option<String>,
}

/// Save a suite:create payload.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn save(kind: &str, payload: Option<&str>, input: Option<&str>) -> Result<i32, CliError> {
    CreateApplication::save_payload(kind, payload, input)?;
    Ok(0)
}
