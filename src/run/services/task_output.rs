use std::fs;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use crate::errors::{CliError, CliErrorKind};

const STABLE_POLLS_REQUIRED: u32 = 2;

/// Wait for a background task output file to stabilize, then return its tail.
///
/// # Errors
/// Returns `CliError` when the file cannot be read or the timeout expires.
pub fn wait_for_task_output(
    output_file: &str,
    timeout_seconds: u64,
    poll_interval_seconds: u64,
    tail_lines: usize,
) -> Result<Vec<String>, CliError> {
    let path = Path::new(output_file);
    let timeout = Duration::from_secs(timeout_seconds);
    let interval = Duration::from_secs(poll_interval_seconds);
    let start = Instant::now();
    let mut previous_size: Option<u64> = None;
    let mut stable_count: u32 = 0;

    loop {
        if start.elapsed() >= timeout {
            return Err(CliErrorKind::io(format!(
                "task wait timed out after {timeout_seconds}s: {output_file}"
            ))
            .into());
        }

        let current_size = file_size(path);
        match (previous_size, current_size) {
            (Some(previous), Some(current)) if current == previous => {
                stable_count += 1;
                if stable_count >= STABLE_POLLS_REQUIRED {
                    break;
                }
            }
            _ => stable_count = 0,
        }

        previous_size = current_size;
        thread::sleep(interval);
    }

    tail_task_output(output_file, tail_lines)
}

/// Return the last N meaningful lines from a task output file.
///
/// # Errors
/// Returns `CliError` when the file cannot be read.
pub fn tail_task_output(output_file: &str, line_count: usize) -> Result<Vec<String>, CliError> {
    let path = Path::new(output_file);
    if !path.exists() {
        return Err(CliErrorKind::missing_file(output_file.to_string()).into());
    }

    let raw = fs::read_to_string(path).map_err(|error| {
        CliErrorKind::io(format!(
            "failed to read task output: {}: {error}",
            path.display()
        ))
    })?;

    let extracted: Vec<String> = raw
        .lines()
        .flat_map(|line| extract_text_content(line).into_iter())
        .collect();
    let start = extracted.len().saturating_sub(line_count);
    Ok(extracted[start..].to_vec())
}

fn extract_text_content(line: &str) -> Vec<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
        return vec![trimmed.to_string()];
    };

    if value.get("type").and_then(serde_json::Value::as_str) != Some("assistant") {
        return Vec::new();
    }

    let Some(content) = value
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(serde_json::Value::as_array)
    else {
        return Vec::new();
    };

    content
        .iter()
        .filter(|entry| entry.get("type").and_then(serde_json::Value::as_str) == Some("text"))
        .filter_map(|entry| entry.get("text").and_then(serde_json::Value::as_str))
        .map(String::from)
        .collect()
}

fn file_size(path: &Path) -> Option<u64> {
    fs::metadata(path).ok().map(|metadata| metadata.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_plain_text_line() {
        let lines = extract_text_content("2026-03-15T18:26:53Z cluster: starting single-up");
        assert_eq!(
            lines,
            vec!["2026-03-15T18:26:53Z cluster: starting single-up"]
        );
    }

    #[test]
    fn extract_empty_line() {
        let lines = extract_text_content("");
        assert!(lines.is_empty());
    }

    #[test]
    fn extract_whitespace_only_line() {
        let lines = extract_text_content("   ");
        assert!(lines.is_empty());
    }

    #[test]
    fn extract_assistant_text_content() {
        let jsonl = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I found the issue."},{"type":"text","text":"The fix is straightforward."}]}}"#;
        let lines = extract_text_content(jsonl);
        assert_eq!(
            lines,
            vec!["I found the issue.", "The fix is straightforward."]
        );
    }

    #[test]
    fn extract_skips_tool_use_in_content() {
        let jsonl = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"ls"}},{"type":"text","text":"Here are the files."}]}}"#;
        let lines = extract_text_content(jsonl);
        assert_eq!(lines, vec!["Here are the files."]);
    }

    #[test]
    fn extract_skips_user_messages() {
        let jsonl = r#"{"type":"user","message":{"role":"user","content":"Do something"}}"#;
        let lines = extract_text_content(jsonl);
        assert!(lines.is_empty());
    }
}
