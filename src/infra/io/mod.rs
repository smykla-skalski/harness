mod markdown;
mod yaml;

use std::io::Write as _;
use std::path::Path;
use std::{fs, io};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, io_for};

pub use self::markdown::{append_markdown_row, as_list, as_mapping, drill};
pub use self::yaml::extract_raw_frontmatter;

/// Check whether a name is safe to use as a path component.
///
/// Returns `false` if the string is empty, contains path separators, or
/// contains `..`.
#[must_use]
pub fn is_safe_name(s: &str) -> bool {
    !s.is_empty() && !s.contains('/') && !s.contains('\\') && !s.contains("..")
}

/// Validate that `segment` is safe to use as a single path component.
///
/// # Errors
/// Returns `CliError` if the segment contains path separators, `..`, or is empty.
pub fn validate_safe_segment(segment: &str) -> Result<(), CliError> {
    if is_safe_name(segment) {
        Ok(())
    } else {
        Err(CliErrorKind::unsafe_name(segment.to_string()).into())
    }
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
/// Returns `CliError` if the file is missing or unreadable.
pub fn read_text(path: &Path) -> Result<String, CliError> {
    fs::read_to_string(path).map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            CliErrorKind::missing_file(path.display().to_string()).into()
        } else {
            io_for("read", path, &e).into()
        }
    })
}

/// Write UTF-8 text to a file, creating parent directories.
///
/// # Errors
/// Returns `CliError` on IO failure.
/// Write UTF-8 text to a file, creating parent directories.
///
/// On Unix, files are created with mode 0600 (owner read/write only).
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_text(path: &Path, text: &str) -> Result<(), CliError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    ensure_dir(parent).map_err(|e| CliError::from(io_for("create dir", parent, &e)))?;
    let mut tmp = tempfile::NamedTempFile::new_in(parent)
        .map_err(|e| io_for("create temp file in", parent, &e))?;
    tmp.write_all(text.as_bytes())
        .map_err(|e| io_for("write temp file for", path, &e))?;
    tmp.flush()
        .map_err(|e| io_for("flush temp file for", path, &e))?;
    tmp.persist(path)
        .map(|_| ())
        .map_err(|e| io_for("persist", path, &e.error))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|e| io_for("set permissions", path, &e))?;
    }

    Ok(())
}

/// Read and parse a JSON file into a `serde_json::Value`.
///
/// # Errors
/// Returns `CliError` if the file is missing or contains invalid JSON.
pub fn read_json(path: &Path) -> Result<Value, CliError> {
    let value: Value = read_json_typed(path)?;
    // Ensure top-level is an object
    ensure_mapping(&value, &format!("JSON document {}", path.display()))?;
    Ok(value)
}

/// Read and parse a JSON file into a typed value.
///
/// # Errors
/// Returns `CliError` if the file is missing or contains invalid JSON.
pub fn read_json_typed<T>(path: &Path) -> Result<T, CliError>
where
    T: DeserializeOwned,
{
    let text = read_text(path)?;
    serde_json::from_str(&text).map_err(|e| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(e.to_string())
    })
}

/// Write a JSON value to a file with pretty-printing.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_json(path: &Path, payload: &Value) -> Result<(), CliError> {
    write_json_pretty(path, payload)
}

/// Write a serializable value to a file as pretty-printed JSON.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_json_pretty<T>(path: &Path, payload: &T) -> Result<(), CliError>
where
    T: Serialize,
{
    let text = serde_json::to_string_pretty(payload)
        .map_err(|e| CliErrorKind::serialize(format!("JSON value: {e}")))?;
    write_text(path, &format!("{text}\n"))
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

    // --- Frontmatter splitter tests ---

    #[test]
    fn extract_frontmatter_valid() {
        let text = "---\nname: test\ncount: 3\n---\n\nBody content here.";
        let (yaml, body) = extract_raw_frontmatter(text).unwrap();
        assert_eq!(yaml, "name: test\ncount: 3");
        assert_eq!(body, "Body content here.");
    }

    #[test]
    fn extract_frontmatter_missing() {
        let err = extract_raw_frontmatter("no frontmatter").unwrap_err();
        assert!(err.message().contains("missing YAML frontmatter"));
    }

    #[test]
    fn extract_frontmatter_unterminated() {
        let err = extract_raw_frontmatter("---\nname: test\n").unwrap_err();
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
    fn validate_safe_segment_accepts_valid() {
        assert!(validate_safe_segment("my-run").is_ok());
        assert!(validate_safe_segment("g01.md").is_ok());
    }

    #[test]
    fn validate_safe_segment_rejects_traversal() {
        let err = validate_safe_segment("../../etc/passwd").unwrap_err();
        assert_eq!(err.code(), "KSRCLI059");
    }

    #[test]
    fn validate_safe_segment_rejects_empty() {
        assert!(validate_safe_segment("").is_err());
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

    #[cfg(unix)]
    #[test]
    fn write_text_sets_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("secret.txt");
        write_text(&path, "sensitive data").unwrap();
        let metadata = fs::metadata(&path).unwrap();
        let mode = metadata.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "expected 0600, got {mode:o}");
    }
}
