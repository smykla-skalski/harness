use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::errors::{CliError, FIELD_TYPE_MISMATCH, MISSING_FIELDS, NOT_A_MAPPING, cli_err};

/// Maximum iterations when probing for missing fields.
/// Each real missing field needs at most 2 iterations (discover + type-fix),
/// so this is generous for any realistic struct.
const MAX_PROBE_ITERATIONS: usize = 100;

/// Deserialize a JSON value into a struct with better error messages.
/// Reports missing field names and type mismatches matching the Python behavior.
///
/// # Errors
///
/// Returns `CliError` when the value is not a mapping, required fields are
/// missing, or field types don't match the target struct.
pub fn from_mapping<T: DeserializeOwned>(value: &Value, label: &str) -> Result<T, CliError> {
    let Some(obj) = value.as_object() else {
        return Err(cli_err(&NOT_A_MAPPING, &[("label", label)]));
    };
    deserialize_with_errors::<T>(obj, label)
}

/// Deserialize from a JSON mapping, merging injected fields first.
/// Handles the "source=false" pattern where some fields come from
/// outside the payload.
///
/// # Errors
///
/// Returns `CliError` when the value is not a mapping, required fields are
/// missing, or field types don't match the target struct.
pub fn from_mapping_with_injected<T: DeserializeOwned>(
    value: &Value,
    injected: &Map<String, Value>,
    label: &str,
) -> Result<T, CliError> {
    let Some(obj) = value.as_object() else {
        return Err(cli_err(&NOT_A_MAPPING, &[("label", label)]));
    };
    let mut merged = obj.clone();
    for (k, v) in injected {
        merged.insert(k.clone(), v.clone());
    }
    deserialize_with_errors::<T>(&merged, label)
}

/// Serialize a struct to a JSON object mapping.
///
/// # Panics
///
/// Panics if `T` cannot be serialized to a JSON object, which should
/// not happen for structs derived with `Serialize`.
#[must_use]
pub fn to_mapping<T: Serialize>(value: &T) -> Map<String, Value> {
    match serde_json::to_value(value).expect("struct serialization cannot fail") {
        Value::Object(m) => m,
        _ => unreachable!("serializing a struct always produces an object"),
    }
}

/// Try to deserialize, collecting all missing fields before reporting.
///
/// Serde reports only the first missing field per attempt. This function
/// iteratively inserts null placeholders (then typed placeholders) to
/// discover all missing fields in a single error.
fn deserialize_with_errors<T: DeserializeOwned>(
    obj: &Map<String, Value>,
    label: &str,
) -> Result<T, CliError> {
    let mut working = obj.clone();
    let mut missing: Vec<String> = Vec::new();
    let mut last_error_msg = String::new();

    for _ in 0..MAX_PROBE_ITERATIONS {
        match serde_json::from_value::<T>(Value::Object(working.clone())) {
            Ok(v) if missing.is_empty() => return Ok(v),
            Ok(_) => {
                let fields = missing.join(", ");
                return Err(cli_err(
                    &MISSING_FIELDS,
                    &[("label", label), ("fields", &fields)],
                ));
            }
            Err(e) => {
                let msg = e.to_string();

                // Detect infinite loops - same error twice means we're stuck.
                if msg == last_error_msg {
                    break;
                }
                last_error_msg.clone_from(&msg);

                if let Some(field) = parse_missing_field(&msg) {
                    missing.push(field.clone());
                    working.insert(field, Value::Null);
                    continue;
                }

                // Null placeholder caused a type error - replace with typed default.
                if msg.contains("invalid type: null") {
                    if let (Some(last), Some(expected)) =
                        (missing.last().cloned(), parse_expected_type(&msg))
                    {
                        working.insert(last, typed_placeholder(&expected));
                        continue;
                    }
                }

                // We have collected some missing fields but hit a different error.
                if !missing.is_empty() {
                    let fields = missing.join(", ");
                    return Err(cli_err(
                        &MISSING_FIELDS,
                        &[("label", label), ("fields", &fields)],
                    ));
                }

                // Type mismatch on a field that was present in the input.
                if let Some(expected) = parse_expected_type(&msg) {
                    return Err(cli_err(
                        &FIELD_TYPE_MISMATCH,
                        &[("label", label), ("field", ""), ("expected", &expected)],
                    ));
                }

                // Unknown serde error - wrap it.
                return Err(CliError {
                    code: "KSRCLI022".to_string(),
                    message: format!("deserialization error in {label}: {msg}"),
                    exit_code: 5,
                    hint: None,
                    details: None,
                });
            }
        }
    }

    // Exhausted iterations - report whatever we found.
    if !missing.is_empty() {
        let fields = missing.join(", ");
        return Err(cli_err(
            &MISSING_FIELDS,
            &[("label", label), ("fields", &fields)],
        ));
    }
    Err(CliError {
        code: "KSRCLI022".to_string(),
        message: format!("deserialization failed for {label}: probe loop exhausted"),
        exit_code: 5,
        hint: None,
        details: None,
    })
}

/// Extract field name from serde's "missing field `X`" error message.
fn parse_missing_field(msg: &str) -> Option<String> {
    let prefix = "missing field `";
    let start = msg.find(prefix)? + prefix.len();
    let end = msg[start..].find('`')? + start;
    Some(msg[start..end].to_string())
}

/// Extract expected type name from serde's "expected a/an TYPE" fragment.
fn parse_expected_type(msg: &str) -> Option<String> {
    let idx = msg.find("expected ")?;
    let rest = &msg[idx + "expected ".len()..];
    let rest = rest.strip_prefix("a ").unwrap_or(rest);
    let rest = rest.strip_prefix("an ").unwrap_or(rest);
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    Some(rest[..end].to_string())
}

/// Build a placeholder value that serde will accept for the given type name,
/// used only during the missing-field probe loop.
fn typed_placeholder(expected: &str) -> Value {
    match expected {
        "string" => Value::String("_placeholder_".to_string()),
        "boolean" => Value::Bool(false),
        "i8" | "i16" | "i32" | "i64" | "u8" | "u16" | "u32" | "u64" | "integer" => {
            Value::Number(0.into())
        }
        "f32" | "f64" | "number" | "float" => {
            Value::Number(serde_json::Number::from_f64(0.0).expect("0.0 is finite"))
        }
        "sequence" | "array" => Value::Array(Vec::new()),
        _ => Value::Object(Map::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use serde_json::json;

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct Simple {
        name: String,
        enabled: bool,
        count: i64,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithDefaults {
        name: String,
        #[serde(default = "default_color")]
        color: String,
        #[serde(default = "default_limit")]
        limit: i64,
    }

    fn default_color() -> String {
        "blue".to_string()
    }

    const fn default_limit() -> i64 {
        10
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithRemap {
        #[serde(rename = "display_name")]
        name: String,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithNonSource {
        name: String,
        injected_path: String,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithEmitFalse {
        name: String,
        #[serde(skip_serializing)]
        internal: String,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithAllowEmpty {
        tag: String,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithTuple {
        items: Vec<String>,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct WithDict {
        config: Map<String, Value>,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct Inner {
        value: String,
    }

    #[derive(Debug, Deserialize, Serialize, PartialEq)]
    struct Outer {
        name: String,
        child: Inner,
    }

    #[test]
    fn test_from_mapping_basic() {
        let input = json!({"name": "foo", "enabled": true, "count": 3});
        let result: Simple = from_mapping(&input, "simple").unwrap();
        assert_eq!(result.name, "foo");
        assert!(result.enabled);
        assert_eq!(result.count, 3);
    }

    #[test]
    fn test_from_mapping_missing_fields() {
        let input = json!({"name": "foo"});
        let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("missing required fields"), "got: {msg}");
        assert!(msg.contains("enabled"), "got: {msg}");
        assert!(msg.contains("count"), "got: {msg}");
    }

    #[test]
    fn test_from_mapping_type_mismatch_str() {
        let input = json!({"name": 42, "enabled": true, "count": 1});
        let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("field type mismatch"), "got: {msg}");
        assert!(msg.contains("expected string"), "got: {msg}");
    }

    #[test]
    fn test_from_mapping_type_mismatch_bool() {
        let input = json!({"name": "x", "enabled": "yes", "count": 1});
        let err = from_mapping::<Simple>(&input, "simple").unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("field type mismatch"), "got: {msg}");
        assert!(msg.contains("expected boolean"), "got: {msg}");
    }

    #[test]
    fn test_from_mapping_allow_empty() {
        let input = json!({"tag": ""});
        let result: WithAllowEmpty = from_mapping(&input, "allowempty").unwrap();
        assert_eq!(result.tag, "");
    }

    #[test]
    fn test_from_mapping_key_remap() {
        let input = json!({"display_name": "hello"});
        let result: WithRemap = from_mapping(&input, "remap").unwrap();
        assert_eq!(result.name, "hello");
    }

    #[test]
    fn test_from_mapping_source_false() {
        let input = json!({"name": "a"});
        let mut injected = Map::new();
        injected.insert("injected_path".to_string(), json!("/tmp/x"));
        let result: WithNonSource =
            from_mapping_with_injected(&input, &injected, "nonsource").unwrap();
        assert_eq!(result.name, "a");
        assert_eq!(result.injected_path, "/tmp/x");
    }

    #[test]
    fn test_from_mapping_emit_false() {
        let input = json!({"name": "a"});
        let mut injected = Map::new();
        injected.insert("internal".to_string(), json!("secret"));
        let obj: WithEmitFalse =
            from_mapping_with_injected(&input, &injected, "emitfalse").unwrap();
        let mapping = to_mapping(&obj);
        assert!(mapping.contains_key("name"));
        assert!(!mapping.contains_key("internal"));
    }

    #[test]
    fn test_from_mapping_tuple_of_str() {
        let input = json!({"items": ["a", "b", "c"]});
        let result: WithTuple = from_mapping(&input, "withtuple").unwrap();
        assert_eq!(result.items, vec!["a", "b", "c"]);
    }

    #[test]
    fn test_from_mapping_dict_field() {
        let input = json!({"config": {"key": "val"}});
        let result: WithDict = from_mapping(&input, "withdict").unwrap();
        let mut expected = Map::new();
        expected.insert("key".to_string(), json!("val"));
        assert_eq!(result.config, expected);
    }

    #[test]
    fn test_from_mapping_nested_struct() {
        let input = json!({"name": "top", "child": {"value": "nested"}});
        let result: Outer = from_mapping(&input, "outer").unwrap();
        assert_eq!(result.name, "top");
        assert_eq!(result.child.value, "nested");
    }

    #[test]
    fn test_to_mapping_round_trip() {
        let original = json!({"name": "foo", "enabled": true, "count": 3});
        let obj: Simple = from_mapping(&original, "simple").unwrap();
        let mapping = to_mapping(&obj);
        assert_eq!(Value::Object(mapping), original);
    }

    #[test]
    fn test_from_mapping_with_defaults() {
        let input = json!({"name": "test"});
        let result: WithDefaults = from_mapping(&input, "with-defaults").unwrap();
        assert_eq!(result.name, "test");
        assert_eq!(result.color, "blue");
        assert_eq!(result.limit, 10);
    }
}
