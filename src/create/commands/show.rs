use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::create::application::CreateApplication;
use crate::errors::CliError;

impl Execute for CreateShowArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        show(&self.kind)
    }
}

/// Arguments for `harness create-show`.
#[derive(Debug, Clone, Args)]
pub struct CreateShowArgs {
    /// Saved suite:create payload kind.
    #[arg(long)]
    pub kind: String,
}

/// Show saved suite:create payloads.
///
/// # Errors
/// Returns `CliError` on failure.
///
/// # Panics
/// Panics if a parsed JSON value fails to re-serialize (should never happen).
pub fn show(kind: &str) -> Result<i32, CliError> {
    let view = CreateApplication::show_payload(kind)?;
    if !view.found {
        println!(r#"{{"found": false, "kind": "{kind}"}}"#);
        return Ok(0);
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&view.value.expect("found payload has a value"))
            .expect("parsed JSON re-serializes")
    );
    Ok(0)
}
