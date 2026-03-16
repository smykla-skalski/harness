use std::io::{self, IsTerminal, Read};
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::io::read_text;

pub(crate) fn read_input(input: Option<&str>, payload: Option<&str>) -> Result<String, CliError> {
    if let Some(text) = payload {
        if text.trim().is_empty() {
            return Err(CliErrorKind::AuthoringPayloadMissing.into());
        }
        return Ok(text.to_string());
    }
    if let Some(path) = input {
        if path == "-" {
            return read_stdin();
        }
        return read_text(Path::new(path));
    }
    if !io::stdin().is_terminal() {
        return read_stdin();
    }
    Err(CliErrorKind::AuthoringPayloadMissing.into())
}

fn read_stdin() -> Result<String, CliError> {
    let mut text = String::new();
    io::stdin()
        .read_to_string(&mut text)
        .map_err(|_| CliError::from(CliErrorKind::AuthoringPayloadMissing))?;
    if text.trim().is_empty() {
        return Err(CliErrorKind::AuthoringPayloadMissing.into());
    }
    Ok(text)
}

pub(crate) fn parse_payload(text: &str, kind: &str) -> Result<serde_json::Value, CliError> {
    // Try raw text first
    if let Ok(value) = serde_json::from_str(text) {
        return Ok(value);
    }
    // Sanitize: strip <json> tags, literal \n escapes, then retry
    let sanitized = sanitize_payload(text);
    serde_json::from_str(&sanitized).map_err(|e| {
        CliErrorKind::authoring_payload_invalid(kind.to_string(), e.to_string()).into()
    })
}

fn sanitize_payload(text: &str) -> String {
    let mut s = text.trim().to_string();
    // Strip XML-style <json> wrapper tags
    if let Some(rest) = s.strip_prefix("<json>") {
        s = rest.to_string();
    }
    if let Some(rest) = s.strip_suffix("</json>") {
        s = rest.to_string();
    }
    // Replace literal backslash-n sequences with actual newlines, then strip them
    s = s.replace("\\n", "\n");
    // Replace literal backslash-quote with actual quotes
    s = s.replace("\\\"", "\"");
    s.trim().to_string()
}
