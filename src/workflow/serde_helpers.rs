use serde_json::Value;

/// Require a string field from a JSON mapping.
///
/// # Errors
/// Returns an error if the field is missing or not a string.
pub fn require_str(
    mapping: &serde_json::Map<String, Value>,
    key: &str,
    label: &str,
) -> Result<String, String> {
    match mapping.get(key) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        _ => Err(format!("{label} `{key}` must be a non-empty string")),
    }
}

/// Get an optional string field.
pub fn optional_str(mapping: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    match mapping.get(key) {
        Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

/// Require a boolean field.
///
/// # Errors
/// Returns an error if the field is not a boolean.
pub fn require_bool(
    mapping: &serde_json::Map<String, Value>,
    key: &str,
    label: &str,
) -> Result<bool, String> {
    match mapping.get(key) {
        Some(Value::Bool(b)) => Ok(*b),
        _ => Err(format!("{label} `{key}` must be a boolean")),
    }
}

/// Require an integer field.
///
/// # Errors
/// Returns an error if the field is not an integer.
pub fn require_int(
    mapping: &serde_json::Map<String, Value>,
    key: &str,
    label: &str,
) -> Result<i64, String> {
    match mapping.get(key) {
        Some(Value::Number(n)) => n
            .as_i64()
            .ok_or_else(|| format!("{label} `{key}` must be an integer")),
        _ => Err(format!("{label} `{key}` must be an integer")),
    }
}

/// Get optional string tuple from a JSON array.
pub fn optional_str_tuple(mapping: &serde_json::Map<String, Value>, key: &str) -> Vec<String> {
    match mapping.get(key) {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {}
