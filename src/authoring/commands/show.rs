use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::application::AuthoringApplication;
use crate::errors::CliError;

impl Execute for AuthoringShowArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        show(&self.kind)
    }
}

/// Arguments for `harness authoring-show`.
#[derive(Debug, Clone, Args)]
pub struct AuthoringShowArgs {
    /// Saved suite:new payload kind.
    #[arg(long)]
    pub kind: String,
}

/// Show saved suite:new payloads.
///
/// # Errors
/// Returns `CliError` on failure.
///
/// # Panics
/// Panics if a parsed JSON value fails to re-serialize (should never happen).
pub fn show(kind: &str) -> Result<i32, CliError> {
    let view = AuthoringApplication::show_payload(kind)?;
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
