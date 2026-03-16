use crate::authoring::{authoring_workspace_dir, require_authoring_session};
use crate::errors::{CliError, CliErrorKind};
use crate::io::{ensure_dir, is_safe_name, write_text};

use super::shared::{parse_payload, read_input};

/// Save a suite:new payload.
///
/// # Errors
/// Returns `CliError` on failure.
///
/// # Panics
/// Panics if a parsed JSON value fails to re-serialize (should never happen).
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
    let json = serde_json::to_string_pretty(&value).expect("parsed JSON re-serializes");
    write_text(&path, &json)?;

    Ok(0)
}
