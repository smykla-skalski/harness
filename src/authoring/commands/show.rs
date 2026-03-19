use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::{authoring_workspace_dir, load_authoring_session};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{is_safe_name, read_text};

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
    if !is_safe_name(kind) {
        return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
    }

    let session = load_authoring_session()?;
    if session.is_none() {
        println!(r#"{{"found": false, "kind": "{kind}"}}"#);
        return Ok(0);
    }
    let workspace = authoring_workspace_dir()?;
    let path = workspace.join(format!("{kind}.json"));

    if !path.exists() {
        println!(r#"{{"found": false, "kind": "{kind}"}}"#);
        return Ok(0);
    }

    let text = read_text(&path)?;
    // Parse and re-serialize for consistent pretty-printed output
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        CliError::from(CliErrorKind::authoring_payload_invalid(
            kind.to_string(),
            e.to_string(),
        ))
    })?;
    println!(
        "{}",
        serde_json::to_string_pretty(&value).expect("parsed JSON re-serializes")
    );
    Ok(0)
}
