use std::fs;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use clap::{Args, Subcommand};

use crate::errors::{CliError, CliErrorKind};

/// Background task output operations.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskCommand {
    /// Wait for a background task to complete by polling its output file.
    Wait {
        /// Full path to the task output file.
        output_file: String,
        /// Maximum seconds to wait before timing out.
        #[arg(long, default_value = "600")]
        timeout: u64,
        /// Seconds between file-size polls.
        #[arg(long, default_value = "10")]
        poll_interval: u64,
        /// Number of tail lines to print when done.
        #[arg(long, default_value = "20")]
        lines: usize,
    },
    /// Print the last N lines of a task output file.
    Tail {
        /// Full path to the task output file.
        output_file: String,
        /// Number of lines to print.
        #[arg(long, default_value = "20")]
        lines: usize,
    },
}

/// Arguments for `harness task`.
#[derive(Debug, Clone, Args)]
pub struct TaskArgs {
    /// Task subcommand.
    #[command(subcommand)]
    pub command: TaskCommand,
}

/// Maximum number of consecutive poll cycles where the file size stays the
/// same before we consider the task complete.
const STABLE_POLLS_REQUIRED: u32 = 2;

/// Dispatch a task subcommand.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn task(command: &TaskCommand) -> Result<i32, CliError> {
    match command {
        TaskCommand::Wait {
            output_file,
            timeout,
            poll_interval,
            lines,
        } => wait(output_file, *timeout, *poll_interval, *lines),
        TaskCommand::Tail { output_file, lines } => tail(output_file, *lines),
    }
}

/// Wait for a background task to complete then print its last N lines.
///
/// The task is considered complete when the output file stops growing for
/// `STABLE_POLLS_REQUIRED` consecutive polls.
///
/// # Errors
/// Returns `CliError` when the file cannot be read or the timeout expires.
fn wait(
    output_file: &str,
    timeout_seconds: u64,
    poll_interval_seconds: u64,
    tail_lines: usize,
) -> Result<i32, CliError> {
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
            // File exists and we have a previous reading to compare against
            (Some(previous), Some(current)) if current == previous => {
                stable_count += 1;
                if stable_count >= STABLE_POLLS_REQUIRED {
                    break;
                }
            }
            // File grew, appeared for the first time, or does not exist yet
            _ => {
                stable_count = 0;
            }
        }

        previous_size = current_size;
        thread::sleep(interval);
    }

    // Task is done - print the tail
    print_tail(path, tail_lines)
}

/// Print the last N lines of a task output file.
///
/// # Errors
/// Returns `CliError` when the file cannot be read.
fn tail(output_file: &str, line_count: usize) -> Result<i32, CliError> {
    let path = Path::new(output_file);
    if !path.exists() {
        return Err(CliErrorKind::missing_file(output_file.to_string()).into());
    }
    print_tail(path, line_count)
}

/// Read a JSONL task output file and print the last N meaningful lines.
///
/// Each line is either plain text or a JSON object. For JSON lines we extract
/// text content from assistant messages. Non-text lines (progress, `tool_use`,
/// user prompts) are skipped.
///
/// # Errors
/// Returns `CliError` when the file cannot be read.
fn print_tail(path: &Path, line_count: usize) -> Result<i32, CliError> {
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
    for line in &extracted[start..] {
        println!("{line}");
    }

    Ok(0)
}

/// Extract human-readable text content from a single line of task output.
///
/// If the line is valid JSON with `"type":"assistant"` and a `message.content`
/// array, we pull out every `{"type":"text","text":"..."}` entry. If the line
/// is plain text (not valid JSON), we return it as-is. Lines that are JSON but
/// contain no text content (progress events, `tool_use`, user messages) return
/// an empty vec.
fn extract_text_content(line: &str) -> Vec<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
        // Not JSON - treat as plain text
        return vec![trimmed.to_string()];
    };

    // Only extract text from assistant messages
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

/// Get the file size in bytes, returning `None` if the file does not exist.
fn file_size(path: &Path) -> Option<u64> {
    fs::metadata(path).ok().map(|metadata| metadata.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- extract_text_content tests --

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

    #[test]
    fn extract_skips_progress_events() {
        let jsonl =
            r#"{"type":"progress","data":{"type":"hook_progress","hookEvent":"PreToolUse"}}"#;
        let lines = extract_text_content(jsonl);
        assert!(lines.is_empty());
    }

    #[test]
    fn extract_assistant_no_text_entries() {
        let jsonl = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file_path":"/tmp/x"}}]}}"#;
        let lines = extract_text_content(jsonl);
        assert!(lines.is_empty());
    }

    #[test]
    fn extract_assistant_missing_content_array() {
        let jsonl = r#"{"type":"assistant","message":{"role":"assistant"}}"#;
        let lines = extract_text_content(jsonl);
        assert!(lines.is_empty());
    }

    // -- print_tail tests --

    #[test]
    fn print_tail_plain_text_file() {
        let directory = tempfile::tempdir().unwrap();
        let file_path = directory.path().join("task.output");
        fs::write(&file_path, "line 1\nline 2\nline 3\nline 4\nline 5\n").unwrap();

        // Just verify it returns Ok(0) - stdout capture is not worth the
        // complexity for a unit test
        let result = print_tail(&file_path, 3);
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn print_tail_mixed_jsonl_file() {
        let directory = tempfile::tempdir().unwrap();
        let file_path = directory.path().join("task.output");
        let content = concat!(
            r#"{"type":"user","message":{"role":"user","content":"Run the test"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running tests now."}]}}"#,
            "\n",
            r#"{"type":"progress","data":{"type":"hook_progress"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All tests passed."}]}}"#,
            "\n",
        );
        fs::write(&file_path, content).unwrap();

        let result = print_tail(&file_path, 20);
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn tail_missing_file_returns_error() {
        let result = tail("/nonexistent/path/task.output", 20);
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert!(error.message().contains("missing file"));
    }

    // -- file_size tests --

    #[test]
    fn file_size_existing_file() {
        let directory = tempfile::tempdir().unwrap();
        let file_path = directory.path().join("test.txt");
        fs::write(&file_path, "hello").unwrap();
        assert_eq!(file_size(&file_path), Some(5));
    }

    #[test]
    fn file_size_nonexistent_file() {
        let path = Path::new("/nonexistent/file.txt");
        assert_eq!(file_size(path), None);
    }

    // -- wait integration-style test --

    #[test]
    fn wait_completes_on_stable_file() {
        let directory = tempfile::tempdir().unwrap();
        let file_path = directory.path().join("task.output");
        fs::write(&file_path, "done\n").unwrap();

        // File already stable - should complete in 2 poll intervals
        let result = wait(
            file_path.to_str().unwrap(),
            30, // timeout
            1,  // poll interval (1s for fast test)
            20, // lines
        );
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn wait_timeout_on_missing_file() {
        let result = wait(
            "/nonexistent/task.output",
            2,  // very short timeout
            1,  // poll interval
            20, // lines
        );
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert!(error.message().contains("timed out"));
    }
}
