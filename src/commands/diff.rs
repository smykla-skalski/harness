use std::path::Path;

use crate::errors::CliError;
use crate::io::{drill, read_text};

fn load_payload(path: &Path) -> Result<serde_json::Value, CliError> {
    let text = read_text(path)?;
    if path.extension().and_then(|e| e.to_str()) == Some("json") {
        serde_json::from_str(&text).map_err(|e| CliError {
            code: "JSON".into(),
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

/// Compute the longest common subsequence table for two slices of lines.
fn lcs_table<'a>(left: &[&'a str], right: &[&'a str]) -> Vec<Vec<usize>> {
    let m = left.len();
    let n = right.len();
    let mut table = vec![vec![0_usize; n + 1]; m + 1];
    for i in 1..=m {
        for j in 1..=n {
            table[i][j] = if left[i - 1] == right[j - 1] {
                table[i - 1][j - 1] + 1
            } else {
                table[i - 1][j].max(table[i][j - 1])
            };
        }
    }
    table
}

/// Produce a simple unified-style diff between two text blocks.
///
/// Uses a longest-common-subsequence algorithm so that duplicate lines,
/// reordered lines, and positional changes are all represented correctly.
/// The output is meant for human consumption, not machine parsing.
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

    let table = lcs_table(&left_lines, &right_lines);
    let mut hunks: Vec<String> = Vec::new();

    // Back-trace through the LCS table to emit diff hunks.
    let mut i = left_lines.len();
    let mut j = right_lines.len();
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && left_lines[i - 1] == right_lines[j - 1] {
            hunks.push(format!(" {}", left_lines[i - 1]));
            i -= 1;
            j -= 1;
        } else if j > 0 && (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
            hunks.push(format!("+{}", right_lines[j - 1]));
            j -= 1;
        } else {
            hunks.push(format!("-{}", left_lines[i - 1]));
            i -= 1;
        }
    }

    hunks.reverse();

    let mut output = vec![format!("--- {left_label}"), format!("+++ {right_label}")];
    output.append(&mut hunks);
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
