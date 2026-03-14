use std::path::Path;

use crate::errors::CliError;
use crate::io::{drill, read_text};

fn load_payload(path: &Path) -> Result<serde_json::Value, CliError> {
    let text = read_text(path)?;
    if path.extension().and_then(|e| e.to_str()) == Some("json") {
        serde_json::from_str(&text).map_err(|e| CliError {
            code: "JSON".to_string(),
            message: format!("invalid JSON in {}: {e}", path.display()),
            exit_code: 5,
            hint: None,
            details: None,
        })
    } else {
        Ok(serde_json::Value::String(text))
    }
}

fn render(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

fn simple_unified_diff(
    left: &str,
    right: &str,
    left_label: &str,
    right_label: &str,
) -> Vec<String> {
    let left_lines: Vec<&str> = left.lines().collect();
    let right_lines: Vec<&str> = right.lines().collect();
    if left_lines == right_lines {
        return Vec::new();
    }
    let mut output = vec![format!("--- {left_label}"), format!("+++ {right_label}")];
    for line in &left_lines {
        if !right_lines.contains(line) {
            output.push(format!("-{line}"));
        }
    }
    for line in &right_lines {
        if !left_lines.contains(line) {
            output.push(format!("+{line}"));
        }
    }
    output
}

/// View diffs between two payloads.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(left: &str, right: &str, path: Option<&str>) -> Result<i32, CliError> {
    let mut left_val = load_payload(Path::new(left))?;
    let mut right_val = load_payload(Path::new(right))?;

    if let Some(dotted) = path {
        left_val = drill(&left_val, dotted)?.clone();
        right_val = drill(&right_val, dotted)?.clone();
    }

    let left_text = render(&left_val);
    let right_text = render(&right_val);

    let diff_lines = simple_unified_diff(&left_text, &right_text, left, right);

    if diff_lines.is_empty() {
        println!("no differences");
        return Ok(0);
    }
    for line in &diff_lines {
        println!("{line}");
    }
    Ok(1)
}
