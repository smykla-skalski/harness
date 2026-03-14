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
#[must_use]
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
#[must_use]
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
mod tests {
    use super::*;
    use serde_json::json;

    fn make_map(value: Value) -> serde_json::Map<String, Value> {
        match value {
            Value::Object(m) => m,
            _ => panic!("expected object"),
        }
    }

    #[test]
    fn require_str_returns_value() {
        let map = make_map(json!({"name": "hello"}));
        assert_eq!(require_str(&map, "name", "test").unwrap(), "hello");
    }

    #[test]
    fn require_str_rejects_empty() {
        let map = make_map(json!({"name": ""}));
        assert!(require_str(&map, "name", "test").is_err());
    }

    #[test]
    fn require_str_rejects_missing() {
        let map = make_map(json!({}));
        let err = require_str(&map, "name", "ctx").unwrap_err();
        assert!(err.contains("ctx"));
        assert!(err.contains("name"));
    }

    #[test]
    fn optional_str_returns_some() {
        let map = make_map(json!({"k": "v"}));
        assert_eq!(optional_str(&map, "k"), Some("v".to_string()));
    }

    #[test]
    fn optional_str_returns_none_for_missing() {
        let map = make_map(json!({}));
        assert_eq!(optional_str(&map, "k"), None);
    }

    #[test]
    fn optional_str_returns_none_for_empty() {
        let map = make_map(json!({"k": ""}));
        assert_eq!(optional_str(&map, "k"), None);
    }

    #[test]
    fn require_bool_works() {
        let map = make_map(json!({"flag": true}));
        assert!(require_bool(&map, "flag", "test").unwrap());
    }

    #[test]
    fn require_bool_rejects_non_bool() {
        let map = make_map(json!({"flag": "yes"}));
        assert!(require_bool(&map, "flag", "test").is_err());
    }

    #[test]
    fn require_int_works() {
        let map = make_map(json!({"count": 42}));
        assert_eq!(require_int(&map, "count", "test").unwrap(), 42);
    }

    #[test]
    fn require_int_rejects_string() {
        let map = make_map(json!({"count": "42"}));
        assert!(require_int(&map, "count", "test").is_err());
    }

    #[test]
    fn optional_str_tuple_returns_strings() {
        let map = make_map(json!({"paths": ["a", "b"]}));
        assert_eq!(optional_str_tuple(&map, "paths"), vec!["a", "b"]);
    }

    #[test]
    fn optional_str_tuple_returns_empty_when_missing() {
        let map = make_map(json!({}));
        assert!(optional_str_tuple(&map, "paths").is_empty());
    }
}
