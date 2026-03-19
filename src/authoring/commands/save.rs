use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::application::AuthoringApplication;
use crate::errors::CliError;

impl Execute for AuthoringSaveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        save(&self.kind, self.payload.as_deref(), self.input.as_deref())
    }
}

/// Arguments for `harness authoring-save`.
#[derive(Debug, Clone, Args)]
pub struct AuthoringSaveArgs {
    /// Suite:new payload kind.
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

/// Save a suite:new payload.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn save(kind: &str, payload: Option<&str>, input: Option<&str>) -> Result<i32, CliError> {
    AuthoringApplication::save_payload(kind, payload, input)?;
    Ok(0)
}
