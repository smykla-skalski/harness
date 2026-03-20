mod markdown;
mod yaml;

use std::io;
use std::io::Write as _;
use std::path::Path;

use fs_err as fs;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, io_for};

pub use self::markdown::{append_markdown_row, as_list, as_mapping, drill};
pub use self::yaml::{FrontmatterDocument, parse_frontmatter};

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
        use std::fs::Permissions;
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, Permissions::from_mode(0o600))
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
mod tests;
