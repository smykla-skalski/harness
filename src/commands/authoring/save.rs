use clap::Args;

use crate::authoring::{authoring_workspace_dir, require_authoring_session};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::{ensure_dir, is_safe_name, write_text};

use super::shared::{parse_payload, read_input};

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
    if !is_safe_name(kind) {
        return Err(CliErrorKind::unsafe_name(kind.to_string()).into());
    }

    let _session = require_authoring_session()?;
    let text = read_input(input, payload)?;
    let value = parse_payload(&text, kind)?;

    let workspace = authoring_workspace_dir()?;
    ensure_dir(&workspace)?;
    let path = workspace.join(format!("{kind}.json"));
    let json = serde_json::to_string_pretty(&value)
        .map_err(|e| CliErrorKind::serialize(cow!("save {kind}: {e}")))?;
    write_text(&path, &json)?;

    Ok(0)
}
