use std::path::Path;

use serde_json::Value;
use tabled::builder::Builder;
use tabled::settings::Style;

use crate::errors::{CliError, CliErrorKind};

use super::{read_text, write_text};

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
