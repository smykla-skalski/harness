use std::collections::HashMap;
use std::path::Path;
use std::{fs, io};

use comrak::nodes::NodeValue;
use comrak::{Arena, Options, parse_document};
use serde_json::Value;
use tabled::builder::Builder;
use tabled::settings::Style;

use crate::errors::{CliError, CliErrorKind, cow};

/// Check whether a name is safe to use as a path component.
///
/// Returns `false` if the string is empty, contains path separators, or
/// contains `..`.
#[must_use]
pub fn is_safe_name(s: &str) -> bool {
    !s.is_empty() && !s.contains('/') && !s.contains('\\') && !s.contains("..")
}

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
        CliErrorKind::not_a_mapping(label.to_string()).into()
    })
}

/// Validate that a JSON value is a list of strings.
///
/// # Errors
/// Returns `CliError` if value is not a list or contains non-strings.
pub fn ensure_str_list(value: &Value, label: &str) -> Result<Vec<String>, CliError> {
    let arr = value
        .as_array()
        .ok_or_else(|| CliError::from(CliErrorKind::not_a_list(label.to_string())))?;
    let mut result = Vec::with_capacity(arr.len());
    for item in arr {
        let s = item
            .as_str()
            .ok_or_else(|| CliError::from(CliErrorKind::not_all_strings(label.to_string())))?;
        result.push(s.to_string());
    }
    Ok(result)
}

/// Ensure a directory exists, creating it and parents if needed.
///
/// # Errors
/// Returns an IO error if directory creation fails.
pub fn ensure_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)
}

/// Read a file as UTF-8 text.
///
/// # Errors
/// Returns `CliError` if the file is missing.
pub fn read_text(path: &Path) -> Result<String, CliError> {
    fs::read_to_string(path)
        .map_err(|_| CliErrorKind::missing_file(path.display().to_string()).into())
}

/// Write UTF-8 text to a file, creating parent directories.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_text(path: &Path, text: &str) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)
            .map_err(|e| CliError::from(CliErrorKind::missing_file(e.to_string())))?;
    }
    fs::write(path, text).map_err(|e| CliErrorKind::missing_file(e.to_string()).into())
}

/// Read and parse a JSON file into a `serde_json::Value`.
///
/// # Errors
/// Returns `CliError` if the file is missing or contains invalid JSON.
pub fn read_json(path: &Path) -> Result<Value, CliError> {
    let text = read_text(path)?;
    let value: Value = serde_json::from_str(&text).map_err(|e| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(e.to_string())
    })?;
    // Ensure top-level is an object
    ensure_mapping(&value, &format!("JSON document {}", path.display()))?;
    Ok(value)
}

/// Write a JSON value to a file with pretty-printing.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_json(path: &Path, payload: &Value) -> Result<(), CliError> {
    let text = serde_json::to_string_pretty(payload)
        .map_err(|e| CliErrorKind::serialize(cow!("JSON value: {e}")))?;
    write_text(path, &format!("{text}\n"))
}

/// Extract raw frontmatter YAML text and body from a markdown document.
///
/// Uses comrak to locate the frontmatter block, then strips delimiters.
/// Returns `(yaml_text, body)`.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or unterminated.
pub fn extract_raw_frontmatter(text: &str) -> Result<(String, String), CliError> {
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
            Err(CliErrorKind::UnterminatedFrontmatter.into())
        } else {
            Err(CliErrorKind::MissingFrontmatter.into())
        };
    };

    // Strip the `---\n ... \n---\n` delimiters to get bare YAML.
    let yaml_text = raw_fm.strip_prefix("---\n").unwrap_or(&raw_fm);
    let yaml_text = if let Some(pos) = yaml_text.rfind("\n---") {
        &yaml_text[..pos]
    } else {
        yaml_text
    };

    // The body is everything after the frontmatter block.
    let body = &text[raw_fm.len()..];
    let body = body.trim_start_matches('\n');

    Ok((yaml_text.to_string(), body.to_string()))
}

/// Parse markdown frontmatter into generic JSON values using comrak for
/// extraction and `serde_yml` for YAML parsing. Returns key-value pairs as
/// `HashMap<String, serde_json::Value>` and the body text.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing or malformed.
pub fn parse_frontmatter_values(text: &str) -> Result<(HashMap<String, Value>, String), CliError> {
    let (yaml_text, body) = extract_raw_frontmatter(text)?;

    let yaml_value: serde_yml::Value = serde_yml::from_str(&yaml_text).map_err(|e| {
        CliErrorKind::UnterminatedFrontmatter.with_details(format!("YAML parse error: {e}"))
    })?;
    let map = yaml_to_json_map(&yaml_value);
    Ok((map, body))
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

/// YAML 1.1 boolean literals that `serde_yml` (YAML 1.2) treats as strings.
fn yaml11_bool(s: &str) -> Option<bool> {
    match s.to_lowercase().as_str() {
        "yes" | "on" => Some(true),
        "no" | "off" => Some(false),
        _ => None,
    }
}

#[must_use]
pub fn yaml_to_json(yaml: &serde_yml::Value) -> Value {
    match yaml {
        serde_yml::Value::Null => Value::Null,
        serde_yml::Value::Bool(b) => Value::Bool(*b),
        serde_yml::Value::String(s) => match yaml11_bool(s) {
            Some(b) => Value::Bool(b),
            None => Value::String(s.clone()),
        },
        serde_yml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Number(i.into())
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number)
            } else {
                Value::Null
            }
        }
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
        return Err(CliErrorKind::MarkdownShapeMismatch.into());
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
            .ok_or_else(|| CliError::from(CliErrorKind::path_not_found(dotted_path.to_string())))?;
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
    fn read_json_rejects_corrupt_json() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("bad.json");
        fs::write(&path, "not json {").unwrap();
        let err = read_json(&path).unwrap_err();
        assert_eq!(err.code(), "KSRCLI019");
    }

    #[test]
    fn read_text_missing_file() {
        let tmp = TempDir::new().unwrap();
        let err = read_text(&tmp.path().join("nope.txt")).unwrap_err();
        assert!(err.message().contains("missing file"));
    }

    #[test]
    fn write_text_creates_parents() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("a").join("b").join("c.txt");
        write_text(&path, "hello").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "hello");
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
        let (payload, _body) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["name"], json!("hello"));
        assert_eq!(payload["count"], json!(42));
        assert_eq!(payload["rate"], json!(3.15));
    }

    #[test]
    fn parse_frontmatter_booleans() {
        let text = "---\nenabled: true\ndisabled: false\nalso_yes: yes\nalso_no: no\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["enabled"], json!(true));
        assert_eq!(payload["disabled"], json!(false));
        // serde_yml treats yes/no as booleans
        assert_eq!(payload["also_yes"], json!(true));
        assert_eq!(payload["also_no"], json!(false));
    }

    #[test]
    fn parse_frontmatter_null() {
        let text = "---\nempty: null\ntilde: ~\nbare:\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["empty"], Value::Null);
        assert_eq!(payload["tilde"], Value::Null);
        assert_eq!(payload["bare"], Value::Null);
    }

    #[test]
    fn parse_frontmatter_inline_list() {
        let text = "---\nitems: [a, b, c]\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["items"], json!(["a", "b", "c"]));
    }

    #[test]
    fn parse_frontmatter_empty_inline_list() {
        let text = "---\nitems: []\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["items"], json!([]));
    }

    #[test]
    fn parse_frontmatter_empty_dict() {
        let text = "---\nmeta: {}\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["meta"], json!({}));
    }

    #[test]
    fn parse_frontmatter_block_list() {
        let text = "---\nitems:\n  - alpha\n  - beta\n  - gamma\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["items"], json!(["alpha", "beta", "gamma"]));
    }

    #[test]
    fn parse_frontmatter_quoted_strings() {
        let text = "---\nname: \"hello world\"\nsingle: 'test'\n---\n\nbody";
        let (payload, _) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["name"], json!("hello world"));
        assert_eq!(payload["single"], json!("test"));
    }

    #[test]
    fn parse_frontmatter_values_valid() {
        let text = "---\nname: test\ncount: 3\n---\n\nBody content here.";
        let (payload, body) = parse_frontmatter_values(text).unwrap();
        assert_eq!(payload["name"], json!("test"));
        assert_eq!(payload["count"], json!(3));
        assert!(body.contains("Body content here."));
    }

    #[test]
    fn parse_frontmatter_values_missing_start() {
        let err = parse_frontmatter_values("no frontmatter").unwrap_err();
        assert!(err.message().contains("missing YAML frontmatter"));
    }

    #[test]
    fn parse_frontmatter_values_unterminated() {
        let err = parse_frontmatter_values("---\nname: test\n").unwrap_err();
        assert!(err.message().contains("unterminated"));
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
        assert!(err.message().contains("path not found"));
    }

    // --- Markdown row tests ---

    #[test]
    fn is_safe_name_accepts_normal_names() {
        assert!(is_safe_name("my-suite"));
        assert!(is_safe_name("g01.md"));
    }

    #[test]
    fn is_safe_name_rejects_unsafe() {
        assert!(!is_safe_name(""));
        assert!(!is_safe_name("a/b"));
        assert!(!is_safe_name("a\\b"));
        assert!(!is_safe_name("a..b"));
    }

    #[test]
    fn append_markdown_row_rejects_shape_mismatch() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("log.md");
        let err = append_markdown_row(&path, &["a", "b"], &["1"]).unwrap_err();
        assert!(
            err.message().contains("shape mismatch"),
            "expected shape mismatch error, got: {}",
            err.message()
        );
    }

    #[test]
    fn append_markdown_row_creates_table() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("log.md");
        append_markdown_row(&path, &["a", "b"], &["1", "2"]).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("| a | b |"));
        assert!(content.contains("| 1 | 2 |"));
    }

    #[test]
    fn append_markdown_row_appends_to_existing() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("log.md");
        append_markdown_row(&path, &["a"], &["1"]).unwrap();
        append_markdown_row(&path, &["a"], &["2"]).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content.matches("| 1 |").count(), 1);
        assert_eq!(content.matches("| 2 |").count(), 1);
    }
}
