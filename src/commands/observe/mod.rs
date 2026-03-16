pub mod classifier;
pub mod output;
pub mod patterns;
pub mod session;
pub mod types;

use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::cli::{ObserveFilterArgs, ObserveMode};
use crate::errors::{CliError, CliErrorKind};

use self::types::{Issue, IssueCategory, IssueSeverity, ScanState};

/// Minimum text length to bother displaying in dump mode.
const MIN_DUMP_TEXT_LENGTH: usize = 5;

/// Maximum characters shown per dump line.
const DUMP_TRUNCATE_LENGTH: usize = 500;

/// Extract text from a `tool_result` content block.
pub(crate) fn tool_result_text(block: &serde_json::Value) -> String {
    let content = &block["content"];
    if let Some(arr) = content.as_array() {
        let parts: Vec<&str> = arr
            .iter()
            .filter_map(|item| {
                if item["type"].as_str() == Some("text") {
                    item["text"].as_str()
                } else {
                    None
                }
            })
            .collect();
        parts.join("\n")
    } else if let Some(s) = content.as_str() {
        s.to_string()
    } else {
        String::new()
    }
}

/// Execute the observe command in the given mode.
///
/// # Errors
/// Returns `CliError` on session lookup or parse failures.
pub fn execute(mode: ObserveMode) -> Result<i32, CliError> {
    match mode {
        ObserveMode::Scan { session_id, filter } => execute_scan(&session_id, &filter),
        ObserveMode::Watch {
            session_id,
            poll_interval,
            timeout,
            filter,
        } => execute_watch(&session_id, poll_interval, timeout, &filter),
        ObserveMode::Dump {
            session_id,
            from_line,
            to_line,
            filter,
            role,
            project_hint,
        } => execute_dump(
            &session_id,
            from_line.unwrap_or(0),
            to_line,
            filter.as_deref(),
            role.as_deref(),
            project_hint.as_deref(),
        ),
        ObserveMode::Context {
            session_id,
            line,
            window,
            project_hint,
        } => execute_context(&session_id, line, window, project_hint.as_deref()),
    }
}

/// One-shot scan returning all classified issues.
fn scan(path: &Path, from_line: usize) -> Result<(Vec<Issue>, usize), CliError> {
    let file = fs::File::open(path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    let mut state = ScanState::default();
    let mut issues = Vec::new();
    let mut last_line = from_line;

    for (index, line_result) in reader.lines().enumerate() {
        if index < from_line {
            continue;
        }
        let line = line_result.map_err(|e| {
            CliErrorKind::session_parse_error(format!("read error at line {index}: {e}"))
        })?;
        last_line = index;
        issues.extend(classifier::classify_line(index, &line, &mut state));
    }

    Ok((issues, last_line))
}

/// Apply filters to a list of issues.
fn apply_filters(issues: Vec<Issue>, filter: &ObserveFilterArgs) -> Vec<Issue> {
    let mut filtered = issues;

    if let Some(ref severity) = filter.severity
        && let Some(min_severity) = IssueSeverity::from_label(severity)
    {
        filtered.retain(|issue| issue.severity >= min_severity);
    }

    if let Some(ref category) = filter.category {
        let categories: Vec<IssueCategory> = category
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        if !categories.is_empty() {
            filtered.retain(|issue| categories.contains(&issue.category));
        }
    }

    if let Some(ref exclude) = filter.exclude {
        let excluded: Vec<IssueCategory> = exclude
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        filtered.retain(|issue| !excluded.contains(&issue.category));
    }

    if filter.fixable {
        filtered.retain(|issue| issue.fixable);
    }

    filtered
}

/// Execute scan mode.
fn execute_scan(session_id: &str, filter: &ObserveFilterArgs) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;

    let status = json!({
        "status": "started",
        "session": path.to_string_lossy(),
        "from_line": filter.from_line,
    });
    println!("{status}");

    let (issues, last_line) = scan(&path, filter.from_line)?;
    let filtered = apply_filters(issues, filter);

    if let Some(ref details_path) = filter.output_details {
        write_details_file(details_path, &filtered)?;
    }

    if filter.json {
        for issue in &filtered {
            println!("{}", output::render_json(issue));
        }
    } else {
        for issue in &filtered {
            println!("{}", output::render_human(issue));
        }
    }

    if filter.summary {
        println!("{}", output::render_summary(&filtered, last_line));
    }

    Ok(0)
}

/// Execute watch mode with polling.
///
/// Tracks the byte offset in the session file so each poll cycle only reads
/// new lines instead of re-reading the entire file.
fn execute_watch(
    session_id: &str,
    poll_interval: u64,
    timeout: u64,
    filter: &ObserveFilterArgs,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;

    let status = json!({
        "status": "started",
        "session": path.to_string_lossy(),
        "from_line": filter.from_line,
    });
    println!("{status}");

    let mut state = ScanState::default();
    let mut all_issues: Vec<Issue> = Vec::new();
    let mut last_line = filter.from_line;
    let mut last_activity = Instant::now();
    let mut byte_offset: u64 = 0;
    let poll_duration = Duration::from_secs(poll_interval);
    let timeout_duration = Duration::from_secs(timeout);

    let open_append = |path: &str, label: &str| -> Result<fs::File, CliError> {
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| {
                CliError::from(CliErrorKind::session_parse_error(format!(
                    "cannot open {label} file: {e}"
                )))
            })
    };

    let mut output_writer: Option<fs::File> = filter
        .output
        .as_deref()
        .map(|p| open_append(p, "output"))
        .transpose()?;
    let mut details_writer: Option<fs::File> = filter
        .output_details
        .as_deref()
        .map(|p| open_append(p, "details"))
        .transpose()?;

    // Skip to from_line on first read by reading through the initial lines
    if filter.from_line > 0
        && let Ok(file) = fs::File::open(&path)
    {
        let reader = BufReader::new(file);
        for (index, line_result) in reader.lines().enumerate() {
            if index >= filter.from_line {
                break;
            }
            if let Ok(line) = line_result {
                // +1 for the newline byte
                byte_offset += line.len() as u64 + 1;
            }
        }
    }

    loop {
        if let Ok(mut file) = fs::File::open(&path) {
            let _ = file.seek(SeekFrom::Start(byte_offset));
            let reader = BufReader::new(file);
            for line_result in reader.lines() {
                let Ok(line) = line_result else {
                    continue;
                };
                byte_offset += line.len() as u64 + 1;
                let index = last_line;
                last_line += 1;

                let new_issues = classifier::classify_line(index, &line, &mut state);
                for issue in &new_issues {
                    if let Some(ref mut detail_out) = details_writer
                        && let Ok(json_str) = serde_json::to_string(issue)
                    {
                        let _ = writeln!(detail_out, "{json_str}");
                        let _ = detail_out.flush();
                    }
                    let rendered = if filter.json {
                        output::render_json(issue)
                    } else {
                        output::render_human(issue)
                    };
                    if let Some(ref mut file_out) = output_writer {
                        let _ = writeln!(file_out, "{rendered}");
                        let _ = file_out.flush();
                    } else {
                        println!("{rendered}");
                    }
                }
                if !new_issues.is_empty() {
                    all_issues.extend(new_issues);
                    last_activity = Instant::now();
                }
            }
        }

        if timeout > 0 && last_activity.elapsed() > timeout_duration {
            break;
        }

        thread::sleep(poll_duration);
    }

    let filtered = apply_filters(all_issues, filter);
    if filter.summary {
        println!("{}", output::render_summary(&filtered, last_line));
    }

    Ok(0)
}

/// Execute dump mode - raw event stream without classification.
fn execute_dump(
    session_id: &str,
    from_line: usize,
    to_line: Option<usize>,
    text_filter: Option<&str>,
    roles: Option<&str>,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, project_hint)?;
    let file = fs::File::open(&path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    let role_set: Option<Vec<&str>> = roles.map(|r| r.split(',').collect());
    let filter_lower: Option<String> = text_filter.map(str::to_lowercase);

    for (index, line_result) in reader.lines().enumerate() {
        if index < from_line {
            continue;
        }
        if to_line.is_some_and(|end| index > end) {
            break;
        }
        let Ok(line) = line_result else {
            continue;
        };
        let Ok(obj) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue;
        };

        let message = &obj["message"];
        if !message.is_object() {
            continue;
        }
        let role = message["role"].as_str().unwrap_or("");
        if role_set.as_ref().is_some_and(|rs| !rs.contains(&role)) {
            continue;
        }

        dump_message_content(index, role, &message["content"], filter_lower.as_deref());
    }

    Ok(0)
}

/// Check if text matches the pre-lowercased dump filter.
fn matches_dump_filter(text: &str, filter_lower: Option<&str>) -> bool {
    filter_lower.is_none_or(|f| text.to_lowercase().contains(f))
}

/// Print content blocks from a message in dump format.
fn dump_message_content(
    index: usize,
    role: &str,
    content: &serde_json::Value,
    filter_lower: Option<&str>,
) {
    if let Some(blocks) = content.as_array() {
        for block in blocks {
            let (label, text) = format_dump_block(index, role, block);
            if text.len() <= MIN_DUMP_TEXT_LENGTH {
                continue;
            }
            if !matches_dump_filter(&text, filter_lower) {
                continue;
            }
            let truncated: String = text.chars().take(DUMP_TRUNCATE_LENGTH).collect();
            println!("{label}: {truncated}");
        }
    } else if let Some(text) = content.as_str() {
        if text.len() <= MIN_DUMP_TEXT_LENGTH {
            return;
        }
        if !matches_dump_filter(text, filter_lower) {
            return;
        }
        let truncated: String = text.chars().take(DUMP_TRUNCATE_LENGTH).collect();
        println!("L{index} [{role}]: {truncated}");
    }
}

/// Format a content block for dump output.
fn format_dump_block(index: usize, role: &str, block: &serde_json::Value) -> (String, String) {
    let block_type = block["type"].as_str().unwrap_or("");
    match block_type {
        "text" => {
            let text = block["text"].as_str().unwrap_or("").to_string();
            (format!("L{index} [{role}] text"), text)
        }
        "tool_use" => format_tool_use_dump(index, role, block),
        "tool_result" => {
            let text = tool_result_text(block);
            (format!("L{index} [{role}] result"), text)
        }
        _ => (format!("L{index} [{role}] {block_type}"), String::new()),
    }
}

/// Format a `tool_use` block for dump output.
fn format_tool_use_dump(index: usize, role: &str, block: &serde_json::Value) -> (String, String) {
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];
    match name {
        "Bash" => {
            let cmd = input["command"].as_str().unwrap_or("");
            (format!("L{index} [{role}] Bash"), cmd.to_string())
        }
        "Read" | "Write" => {
            let file_path = input["file_path"].as_str().unwrap_or("");
            (format!("L{index} [{role}] {name}"), file_path.to_string())
        }
        "Edit" => {
            let file_path = input["file_path"].as_str().unwrap_or("");
            let old: String = input["old_string"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(100)
                .collect();
            let new_str: String = input["new_string"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(100)
                .collect();
            let text = format!("{file_path}\n  old: {old}\n  new: {new_str}");
            (format!("L{index} [{role}] Edit"), text)
        }
        "AskUserQuestion" => {
            let questions = input["questions"].as_array();
            let parts: Vec<String> = questions
                .iter()
                .flat_map(|qs| qs.iter())
                .map(|q| {
                    let header = q["header"].as_str().unwrap_or("");
                    let question = q["question"].as_str().unwrap_or("");
                    format!("header={header}, q={question}")
                })
                .collect();
            let text = parts.join("; ");
            (format!("L{index} [{role}] AskUser"), text)
        }
        "Agent" => {
            let desc = input["description"].as_str().unwrap_or("");
            (format!("L{index} [{role}] Agent"), desc.to_string())
        }
        _ => {
            let text: String = serde_json::to_string(input)
                .unwrap_or_default()
                .chars()
                .take(300)
                .collect();
            (format!("L{index} [{role}] {name}"), text)
        }
    }
}

/// Execute context mode - show events around a specific line.
fn execute_context(
    session_id: &str,
    target_line: usize,
    window: usize,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let start = target_line.saturating_sub(window);
    let end = target_line + window;
    execute_dump(session_id, start, Some(end), None, None, project_hint)
}

/// Write full untruncated issue details to a file.
fn write_details_file(path: &str, issues: &[Issue]) -> Result<(), CliError> {
    let mut file = fs::File::create(path).map_err(|e| {
        CliErrorKind::session_parse_error(format!("cannot create details file: {e}"))
    })?;
    for issue in issues {
        if let Ok(json_str) = serde_json::to_string(issue) {
            let _ = writeln!(file, "{json_str}");
        }
    }
    Ok(())
}
