use std::path::Path;

use crate::authoring::{authoring_workspace_dir, require_authoring_session};
use crate::errors::{self, CliError};
use crate::io::{ensure_dir, is_safe_name, read_text, write_text};

fn read_input(input: Option<&str>, payload: Option<&str>) -> Result<String, CliError> {
    if let Some(text) = payload {
        if text.trim().is_empty() {
            return Err(errors::cli_err(&errors::AUTHORING_PAYLOAD_MISSING, &[]));
        }
        return Ok(text.to_string());
    }
    if let Some(path) = input {
        if path == "-" {
            return Err(errors::cli_err(&errors::AUTHORING_PAYLOAD_MISSING, &[]));
        }
        return read_text(Path::new(path));
    }
    Err(errors::cli_err(&errors::AUTHORING_PAYLOAD_MISSING, &[]))
}

fn parse_payload(text: &str, kind: &str) -> Result<serde_json::Value, CliError> {
    serde_json::from_str(text).map_err(|e| {
        errors::cli_err(
            &errors::AUTHORING_PAYLOAD_INVALID,
            &[("kind", kind), ("details", &e.to_string())],
        )
    })
}

/// Save a suite-author payload.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(kind: &str, payload: Option<&str>, input: Option<&str>) -> Result<i32, CliError> {
    if !is_safe_name(kind) {
        return Err(errors::cli_err(&errors::UNSAFE_NAME, &[("name", kind)]));
    }

    let _session = require_authoring_session()?;
    let text = read_input(input, payload)?;
    let value = parse_payload(&text, kind)?;

    let workspace = authoring_workspace_dir();
    ensure_dir(&workspace).map_err(errors::io_err)?;
    let path = workspace.join(format!("{kind}.json"));
    let json = serde_json::to_string_pretty(&value).unwrap_or_default();
    write_text(&path, &json)?;

    Ok(0)
}
