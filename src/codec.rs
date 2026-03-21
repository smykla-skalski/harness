use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::errors::{CliError, CliErrorKind};

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
        return Err(CliErrorKind::not_a_mapping(label.to_string()).into());
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
        return Err(CliErrorKind::not_a_mapping(label.to_string()).into());
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
                return Err(CliErrorKind::missing_fields(label.to_string(), fields).into());
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
                if msg.contains("invalid type: null")
                    && let (Some(last), Some(expected)) =
                        (missing.last().cloned(), parse_expected_type(&msg))
                {
                    working.insert(last, typed_placeholder(&expected));
                    continue;
                }

                // We have collected some missing fields but hit a different error.
                if !missing.is_empty() {
                    let fields = missing.join(", ");
                    return Err(CliErrorKind::missing_fields(label.to_string(), fields).into());
                }

                // Type mismatch on a field that was present in the input.
                if let Some(expected) = parse_expected_type(&msg) {
                    let field = identify_mismatched_field::<T>(&working, &expected);
                    return Err(CliErrorKind::field_type_mismatch(
                        label.to_string(),
                        field,
                        expected,
                    )
                    .into());
                }

                // Unknown serde error - wrap it.
                return Err(CliErrorKind::field_type_mismatch(
                    label.to_string(),
                    "(unknown field)",
                    msg,
                )
                .into());
            }
        }
    }

    // Exhausted iterations - report whatever we found.
    if !missing.is_empty() {
        let fields = missing.join(", ");
        return Err(CliErrorKind::missing_fields(label.to_string(), fields).into());
    }
    Err(CliErrorKind::field_type_mismatch(label.to_string(), "", "probe loop exhausted").into())
}

/// Identify which field in `obj` causes a type mismatch by probing each key.
///
/// Replaces each key's value with a typed placeholder and attempts deserialization.
/// If replacing a key makes deserialization succeed (or changes the error), that
/// key was the mismatched field.
fn identify_mismatched_field<T: DeserializeOwned>(
    obj: &Map<String, Value>,
    expected: &str,
) -> String {
    let placeholder = typed_placeholder(expected);
    for key in obj.keys() {
        let mut probe = obj.clone();
        probe.insert(key.clone(), placeholder.clone());
        if serde_json::from_value::<T>(Value::Object(probe)).is_ok() {
            return key.clone();
        }
    }
    "(unknown field)".to_string()
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
#[path = "codec/tests.rs"]
mod tests;
