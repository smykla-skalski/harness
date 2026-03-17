use std::collections::HashMap;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io;

/// Split frontmatter from body using the shared `io::extract_raw_frontmatter`
/// helper. Returns parsed YAML mapping and body text.
pub(super) fn split_frontmatter(text: &str) -> Result<(serde_yml::Mapping, String), CliError> {
    let (yaml_text, body) = io::extract_raw_frontmatter(text)?;
    let map: serde_yml::Mapping = serde_yml::from_str(&yaml_text)
        .map_err(|e| CliErrorKind::workflow_parse(cow!("frontmatter YAML: {e}")))?;
    Ok((map, body))
}

/// Extract a string field from a YAML mapping, returning None if missing or not a string.
pub(super) fn yaml_str(map: &serde_yml::Mapping, key: &str) -> Option<String> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_str)
        .map(String::from)
}

/// Extract a bool field, defaulting to false.
pub(super) fn yaml_bool(map: &serde_yml::Mapping, key: &str) -> bool {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_bool)
        .unwrap_or(false)
}

/// Extract a list-of-strings field, defaulting to empty vec.
pub(super) fn yaml_str_list(map: &serde_yml::Mapping, key: &str) -> Vec<String> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_sequence)
        .map(|seq| {
            seq.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// Extract a list-of-integers field, defaulting to empty vec.
pub(super) fn yaml_int_list(map: &serde_yml::Mapping, key: &str) -> Vec<i64> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_sequence)
        .map(|seq| seq.iter().filter_map(serde_yml::Value::as_i64).collect())
        .unwrap_or_default()
}

/// Extract `helm_values` as a `HashMap<String, serde_json::Value>`.
pub(super) fn yaml_helm_values(
    map: &serde_yml::Mapping,
    key: &str,
) -> HashMap<String, serde_json::Value> {
    let Some(val) = map.get(serde_yml::Value::String(key.to_string())) else {
        return HashMap::new();
    };
    let Some(mapping) = val.as_mapping() else {
        return HashMap::new();
    };
    mapping
        .iter()
        .filter_map(|(k, v)| {
            let key_str = k.as_str()?;
            let json_val = io::yaml_to_json(v);
            Some((key_str.to_string(), json_val))
        })
        .collect()
}
