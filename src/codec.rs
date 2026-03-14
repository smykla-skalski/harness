use serde_json::Value;

use crate::errors::CliError;

/// Deserialize a JSON value into a struct with better error messages.
/// Reports missing field names and type mismatches matching the Python behavior.
///
/// # Errors
/// Returns `CliError` with field-level error details.
pub fn from_mapping<T: serde::de::DeserializeOwned>(
    _value: &Value,
    _label: &str,
) -> Result<T, CliError> {
    todo!()
}

/// Deserialize from a JSON mapping, allowing injection of additional fields
/// that don't come from the payload (the "source=false" pattern from Python).
///
/// # Errors
/// Returns `CliError` with field-level error details.
pub fn from_mapping_with_injected<T: serde::de::DeserializeOwned>(
    _value: &Value,
    _injected: &serde_json::Map<String, Value>,
    _label: &str,
) -> Result<T, CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
