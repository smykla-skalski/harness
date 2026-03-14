use crate::authoring::{authoring_workspace_dir, require_authoring_session};
use crate::errors::{self, CliError};
use crate::io::read_text;

/// Show saved suite-author payloads.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(kind: &str) -> Result<i32, CliError> {
    let _session = require_authoring_session()?;
    let workspace = authoring_workspace_dir();
    let path = workspace.join(format!("{kind}.json"));

    if !path.exists() {
        return Err(errors::cli_err(
            &errors::AUTHORING_SHOW_KIND_MISSING,
            &[("kind", kind)],
        ));
    }

    let text = read_text(&path)?;
    // Parse and re-serialize for consistent pretty-printed output
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
        errors::cli_err(
            &errors::AUTHORING_PAYLOAD_INVALID,
            &[("kind", kind), ("details", &e.to_string())],
        )
    })?;
    println!(
        "{}",
        serde_json::to_string_pretty(&value).unwrap_or_default()
    );
    Ok(0)
}
