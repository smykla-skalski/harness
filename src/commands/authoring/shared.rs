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
            return Err(CliErrorKind::AuthoringPayloadMissing.into());
        }
        return read_text(Path::new(path));
    }
    Err(CliErrorKind::AuthoringPayloadMissing.into())
}

pub(crate) fn parse_payload(text: &str, kind: &str) -> Result<serde_json::Value, CliError> {
    serde_json::from_str(text).map_err(|e| {
        CliErrorKind::authoring_payload_invalid(kind.to_string(), e.to_string()).into()
    })
}
