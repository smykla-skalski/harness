use std::collections::HashMap;
use std::path::Path;

use comrak::nodes::NodeValue;
use comrak::{Arena, Options, parse_document};
use serde_json::Value;
use tabled::builder::Builder;
use tabled::settings::Style;

use crate::errors::{
    self, CliError, MARKDOWN_SHAPE_MISMATCH, MISSING_FILE, MISSING_FRONTMATTER, NOT_A_LIST,
    NOT_A_MAPPING, NOT_ALL_STRINGS, NOT_STRING_KEYS, PATH_NOT_FOUND, UNTERMINATED_FRONTMATTER,
};

/// Validate that a JSON value is an object with string keys.
///
/// # Errors
/// Returns `CliError` if value is not a mapping or has non-string keys.
pub fn ensure_mapping<'a>(
    value: &'a Value,
    label: &str,
) -> Result<&'a serde_json::Map<String, Value>, CliError> {
    value.as_object().ok_or_else(|| {
        // JSON objects always have string keys, so we only need to check
        // that the value is actually an object.
        errors::cli_err(&NOT_A_MAPPING, &[("label", label)])
    })
}

/// Validate that a JSON value is a list of strings.
///
/// # Errors
/// Returns `CliError` if value is not a list or contains non-strings.
pub fn ensure_str_list(value: &Value, label: &str) -> Result<Vec<String>, CliError> {
    let arr = value
        .as_array()
        .ok_or_else(|| errors::cli_err(&NOT_A_LIST, &[("label", label)]))?;
    let mut result = Vec::with_capacity(arr.len());
    for item in arr {
        let s = item
            .as_str()
            .ok_or_else(|| errors::cli_err(&NOT_ALL_STRINGS, &[("label", label)]))?;
        result.push(s.to_string());
    }
    Ok(result)
}

/// Ensure a directory exists, creating it and parents if needed.
///
/// # Errors
/// Returns an IO error if directory creation fails.
pub fn ensure_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)
}

/// Read a file as UTF-8 text.
///
/// # Errors
/// Returns `CliError` if the file is missing.
pub fn read_text(path: &Path) -> Result<String, CliError> {
    std::fs::read_to_string(path)
        .map_err(|_| errors::cli_err(&MISSING_FILE, &[("path", &path.display().to_string())]))
}

/// Write UTF-8 text to a file, creating parent directories.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_text(path: &Path, text: &str) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)
            .map_err(|e| errors::cli_err(&MISSING_FILE, &[("path", &e.to_string())]))?;
    }
    std::fs::write(path, text)
        .map_err(|e| errors::cli_err(&MISSING_FILE, &[("path", &e.to_string())]))
}

/// Read and parse a JSON file into a `serde_json::Value`.
///
/// # Errors
/// Returns `CliError` if the file is missing or contains invalid JSON.
pub fn read_json(path: &Path) -> Result<Value, CliError> {
    let text = read_text(path)?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| errors::cli_err(&MISSING_FILE, &[("path", &e.to_string())]))?;
    // Ensure top-level is an object
    let _ = ensure_mapping(&value, &format!("JSON document {}", path.display()))?;
    Ok(value)
}

/// Write a JSON value to a file with pretty-printing.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_json(path: &Path, payload: &Value) -> Result<(), CliError> {
    let text = serde_json::to_string_pretty(payload).expect("serialization of valid JSON value");
    write_text(path, &format!("{text}\n"))
}

/// Parse markdown frontmatter using comrak for extraction and serde_yml for
/// YAML parsing.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or malformed.
pub fn split_frontmatter(text: &str) -> Result<(HashMap<String, Value>, String), CliError> {
    let mut options = Options::default();
    options.extension.front_matter_delimiter = Some("---".to_owned());

    let arena = Arena::new();
    let root = parse_document(&arena, text, &options);

    let fm_content = root.descendants().find_map(|node| {
        let data = node.data.borrow();
        if let NodeValue::FrontMatter(ref content) = data.value {
            Some(content.clone())
        } else {
            None
        }
    });

    let Some(raw_fm) = fm_content else {
        return if text.starts_with("---\n") {
            Err(errors::cli_err(&UNTERMINATED_FRONTMATTER, &[]))
        } else {
            Err(errors::cli_err(&MISSING_FRONTMATTER, &[]))
        };
    };

    // Strip the `---\n ... \n---\n` delimiters to get bare YAML.
    let yaml_text = raw_fm.strip_prefix("---\n").unwrap_or(&raw_fm);
    // Find the closing delimiter and take everything before it.
    let yaml_text = if let Some(pos) = yaml_text.rfind("\n---") {
        &yaml_text[..pos]
    } else {
        yaml_text
    };

    // The body is everything after the frontmatter block.
    let body = &text[raw_fm.len()..];
    let body = body.trim_start_matches('\n');

    let yaml_value: serde_yml::Value = serde_yml::from_str(yaml_text).map_err(|e| {
        errors::cli_err_with_details(
            &UNTERMINATED_FRONTMATTER,
            &[],
            &format!("YAML parse error: {e}"),
        )
    })?;
    let map = yaml_to_json_map(&yaml_value);
    Ok((map, body.to_string()))
}

fn yaml_to_json_map(yaml: &serde_yml::Value) -> HashMap<String, Value> {
    let mut result = HashMap::new();
    if let serde_yml::Value::Mapping(mapping) = yaml {
        for (k, v) in mapping {
            if let serde_yml::Value::String(key) = k {
                result.insert(key.clone(), yaml_to_json(v));
            }
        }
    }
    result
}

/// YAML 1.1 boolean literals that serde_yml (YAML 1.2) treats as strings.
fn yaml11_bool(s: &str) -> Option<bool> {
    match s.to_lowercase().as_str() {
        "yes" | "on" => Some(true),
        "no" | "off" => Some(false),
        _ => None,
    }
}

fn yaml_to_json(yaml: &serde_yml::Value) -> Value {
    match yaml {
        serde_yml::Value::Null => Value::Null,
        serde_yml::Value::Bool(b) => Value::Bool(*b),
        serde_yml::Value::String(s) if yaml11_bool(s).is_some() => {
            Value::Bool(yaml11_bool(s).unwrap())
        }
        serde_yml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Number(i.into())
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f)
                    .map(Value::Number)
                    .unwrap_or(Value::Null)
            } else {
                Value::Null
            }
        }
        serde_yml::Value::String(s) => Value::String(s.clone()),
        serde_yml::Value::Sequence(seq) => Value::Array(seq.iter().map(yaml_to_json).collect()),
        serde_yml::Value::Mapping(m) => {
            let mut map = serde_json::Map::new();
            for (k, v) in m {
                if let serde_yml::Value::String(key) = k {
                    map.insert(key.clone(), yaml_to_json(v));
                }
            }
            Value::Object(map)
        }
        serde_yml::Value::Tagged(tagged) => yaml_to_json(&tagged.value),
    }
}

/// Append a row to a markdown table file, creating the file with headers if needed.
///
/// # Errors
/// Returns `CliError` on shape mismatch or IO failure.
pub fn append_markdown_row(path: &Path, headers: &[&str], values: &[&str]) -> Result<(), CliError> {
    if headers.len() != values.len() {
        return Err(errors::cli_err(&MARKDOWN_SHAPE_MISMATCH, &[]));
    }
    let current = if path.exists() {
        let text = read_text(path)?;
        // Verify that the caller's headers match the existing table.
        if let Some(header_line) = text.lines().find(|l| l.starts_with('|')) {
            let existing: Vec<&str> = header_line
                .split('|')
                .filter(|s| !s.trim().is_empty())
                .map(str::trim)
                .collect();
            debug_assert!(
                existing == headers,
                "append_markdown_row: caller headers {headers:?} do not match existing {existing:?}"
            );
        }
        text
    } else {
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("table");
        let title = stem.replace('-', " ");
        // Title-case each word
        let title: String = title
            .split_whitespace()
            .map(|w| {
                let mut chars = w.chars();
                match chars.next() {
                    Some(c) => {
                        let upper: String = c.to_uppercase().collect();
                        format!("{upper}{rest}", rest = chars.as_str())
                    }
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        let mut builder = Builder::default();
        builder.push_record(headers.iter().copied());
        let mut table = builder.build();
        table.with(Style::markdown());
        format!("# {title}\n\n{table}\n")
    };
    let escaped: Vec<String> = values
        .iter()
        .map(|v| v.replace('|', "\\|").replace('\n', "<br>"))
        .collect();
    let row = escaped.join(" | ");
    let output = format!("{current}| {row} |\n");
    write_text(path, &output)
}

/// Navigate a JSON value using a dotted path (e.g. "a.b.c").
///
/// # Errors
/// Returns `CliError` if any path segment is not found.
pub fn drill<'a>(payload: &'a Value, dotted_path: &str) -> Result<&'a Value, CliError> {
    let mut current = payload;
    for part in dotted_path.split('.') {
        current = current
            .get(part)
            .ok_or_else(|| errors::cli_err(&PATH_NOT_FOUND, &[("dotted_path", dotted_path)]))?;
    }
    Ok(current)
}

/// Check if a JSON value is an object with string keys, returning it or None.
#[must_use]
pub fn as_mapping(value: &Value) -> Option<&serde_json::Map<String, Value>> {
    value.as_object()
}

/// Return value as array, or empty slice if not an array.
#[must_use]
pub fn as_list(value: &Value) -> &[Value] {
    value.as_array().map_or(&[], Vec::as_slice)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    #[test]
    fn write_and_read_json() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("test.json");
        let payload = json!({"key": "value", "num": 42});
        write_json(&path, &payload).unwrap();
        let data = read_json(&path).unwrap();
        assert_eq!(data["key"], "value");
        assert_eq!(data["num"], 42);
    }

    #[test]
    fn read_text_missing_file() {
        let tmp = TempDir::new().unwrap();
        let err = read_text(&tmp.path().join("nope.txt")).unwrap_err();
        assert!(err.message.contains("missing file"));
    }

    #[test]
    fn write_text_creates_parents() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("a").join("b").join("c.txt");
        write_text(&path, "hello").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello");
    }

    #[test]
    fn ensure_mapping_rejects_non_dict() {
        let val = json!("string");
        assert!(ensure_mapping(&val, "test").is_err());
    }

    #[test]
    fn ensure_str_list_rejects_non_strings() {
        let val = json!([1, 2, 3]);
        assert!(ensure_str_list(&val, "test").is_err());
    }

    // --- Frontmatter parser tests ---

    #[test]
    fn parse_frontmatter_scalars() {
        let text = "---\nname: hello\ncount: 42\nrate: 3.15\n---\n\nbody";
        let (payload, _body) = split_frontmatter(text).unwrap();
        assert_eq!(payload["name"], json!("hello"));
        assert_eq!(payload["count"], json!(42));
        assert_eq!(payload["rate"], json!(3.15));
    }

    #[test]
    fn parse_frontmatter_booleans() {
        let text = "---\nenabled: true\ndisabled: false\nalso_yes: yes\nalso_no: no\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["enabled"], json!(true));
        assert_eq!(payload["disabled"], json!(false));
        // serde_yml treats yes/no as booleans
        assert_eq!(payload["also_yes"], json!(true));
        assert_eq!(payload["also_no"], json!(false));
    }

    #[test]
    fn parse_frontmatter_null() {
        let text = "---\nempty: null\ntilde: ~\nbare:\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["empty"], Value::Null);
        assert_eq!(payload["tilde"], Value::Null);
        assert_eq!(payload["bare"], Value::Null);
    }

    #[test]
    fn parse_frontmatter_inline_list() {
        let text = "---\nitems: [a, b, c]\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["items"], json!(["a", "b", "c"]));
    }

    #[test]
    fn parse_frontmatter_empty_inline_list() {
        let text = "---\nitems: []\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["items"], json!([]));
    }

    #[test]
    fn parse_frontmatter_empty_dict() {
        let text = "---\nmeta: {}\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["meta"], json!({}));
    }

    #[test]
    fn parse_frontmatter_block_list() {
        let text = "---\nitems:\n  - alpha\n  - beta\n  - gamma\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["items"], json!(["alpha", "beta", "gamma"]));
    }

    #[test]
    fn parse_frontmatter_quoted_strings() {
        let text = "---\nname: \"hello world\"\nsingle: 'test'\n---\n\nbody";
        let (payload, _) = split_frontmatter(text).unwrap();
        assert_eq!(payload["name"], json!("hello world"));
        assert_eq!(payload["single"], json!("test"));
    }

    #[test]
    fn split_frontmatter_valid() {
        let text = "---\nname: test\ncount: 3\n---\n\nBody content here.";
        let (payload, body) = split_frontmatter(text).unwrap();
        assert_eq!(payload["name"], json!("test"));
        assert_eq!(payload["count"], json!(3));
        assert!(body.contains("Body content here."));
    }

    #[test]
    fn split_frontmatter_missing_start() {
        let err = split_frontmatter("no frontmatter").unwrap_err();
        assert!(err.message.contains("missing YAML frontmatter"));
    }

    #[test]
    fn split_frontmatter_unterminated() {
        let err = split_frontmatter("---\nname: test\n").unwrap_err();
        assert!(err.message.contains("unterminated"));
    }

    // --- JSON navigation tests ---

    #[test]
    fn as_mapping_returns_none_for_non_dict() {
        assert!(as_mapping(&json!("string")).is_none());
        assert!(as_mapping(&json!(42)).is_none());
    }

    #[test]
    fn as_mapping_returns_map() {
        let val = json!({"key": "value"});
        let map = as_mapping(&val).unwrap();
        assert_eq!(map.get("key").unwrap(), &json!("value"));
    }

    #[test]
    fn as_list_returns_empty_for_non_list() {
        assert!(as_list(&json!("string")).is_empty());
    }

    #[test]
    fn drill_navigates_nested_dicts() {
        let data = json!({"a": {"b": {"c": "found"}}});
        assert_eq!(drill(&data, "a.b.c").unwrap(), &json!("found"));
    }

    #[test]
    fn drill_raises_on_missing_path() {
        let data = json!({"a": 1});
        let err = drill(&data, "a.b.c").unwrap_err();
        assert!(err.message.contains("path not found"));
    }

    // --- Markdown row tests ---

    #[test]
    fn append_markdown_row_creates_table() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("log.md");
        append_markdown_row(&path, &["a", "b"], &["1", "2"]).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("| a | b |"));
        assert!(content.contains("| 1 | 2 |"));
    }

    #[test]
    fn append_markdown_row_appends_to_existing() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("log.md");
        append_markdown_row(&path, &["a"], &["1"]).unwrap();
        append_markdown_row(&path, &["a"], &["2"]).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content.matches("| 1 |").count(), 1);
        assert_eq!(content.matches("| 2 |").count(), 1);
    }
}
