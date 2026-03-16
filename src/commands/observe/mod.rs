pub mod classifier;
pub mod output;
pub mod patterns;
pub mod session;
pub mod types;

use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
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

/// Maximum characters stored in issue detail fields.
const MAX_DETAIL_LENGTH: usize = 2000;

/// Truncate text to at most `max_len` bytes at a valid UTF-8 char boundary.
fn truncate_at(text: &str, max_len: usize) -> &str {
    if text.len() <= max_len {
        text
    } else {
        &text[..text.floor_char_boundary(max_len)]
    }
}

/// Cap issue detail text at construction time.
pub(crate) fn truncate_details(text: &str) -> String {
    truncate_at(text, MAX_DETAIL_LENGTH).to_string()
}

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
        ObserveMode::Cycle {
            session_id,
            project_hint,
        } => execute_cycle(&session_id, project_hint.as_deref()),
        ObserveMode::Context {
            session_id,
            line,
            window,
            project_hint,
        } => execute_context(&session_id, line, window, project_hint.as_deref()),
    }
}

/// State file path for a session observer.
fn state_file_path(session_id: &str) -> PathBuf {
    env::temp_dir().join(format!("observe-{session_id}.state"))
}

/// Execute one observer cycle: read cursor, scan, update cursor, report.
fn execute_cycle(session_id: &str, project_hint: Option<&str>) -> Result<i32, CliError> {
    let state_path = state_file_path(session_id);
    let from_line = if state_path.exists() {
        let content = fs::read_to_string(&state_path).map_err(|e| {
            CliErrorKind::session_parse_error(format!("cannot read state file: {e}"))
        })?;
        let parsed: serde_json::Value = serde_json::from_str(&content).map_err(|e| {
            CliErrorKind::session_parse_error(format!("invalid state file JSON: {e}"))
        })?;
        usize::try_from(parsed["cursor"].as_u64().unwrap_or(0)).unwrap_or(0)
    } else {
        0
    };

    let path = session::find_session(session_id, project_hint)?;
    let (issues, last_line) = scan(&path, from_line)?;

    // Update cursor
    let state = json!({"cursor": last_line, "session_id": session_id});
    fs::write(&state_path, state.to_string())
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot write state file: {e}")))?;

    if issues.is_empty() {
        return Ok(0);
    }

    // Report
    let critical_count = issues
        .iter()
        .filter(|i| i.severity == IssueSeverity::Critical)
        .count();
    println!(
        "Cycle: lines {from_line}-{last_line}, {} new issues ({critical_count} critical)",
        issues.len()
    );
    for issue in &issues {
        println!("{}", output::render_json(issue));
    }
    println!("{}", output::render_summary(&issues, last_line));

    Ok(0)
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

/// Compute the byte offset for skipping the first `from_line` lines.
fn compute_initial_byte_offset(path: &Path, from_line: usize) -> u64 {
    if from_line == 0 {
        return 0;
    }
    let Ok(file) = fs::File::open(path) else {
        return 0;
    };
    let reader = BufReader::new(file);
    let mut offset = 0u64;
    for (index, line_result) in reader.lines().enumerate() {
        if index >= from_line {
            break;
        }
        if let Ok(line) = line_result {
            offset += line.len() as u64 + 1;
        }
    }
    offset
}

/// Read new lines from the session file at the current byte offset and classify them.
fn poll_session_lines(
    path: &Path,
    byte_offset: &mut u64,
    last_line: &mut usize,
    state: &mut ScanState,
) -> Vec<Issue> {
    let Ok(mut file) = fs::File::open(path) else {
        return Vec::new();
    };
    let _ = file.seek(SeekFrom::Start(*byte_offset));
    let reader = BufReader::new(file);
    let mut issues = Vec::new();
    for line_result in reader.lines() {
        let Ok(line) = line_result else { continue };
        *byte_offset += line.len() as u64 + 1;
        let index = *last_line;
        *last_line += 1;
        issues.extend(classifier::classify_line(index, &line, state));
    }
    issues
}

/// Write an issue to the appropriate outputs (details file, output file, or stdout).
fn emit_watch_issue(
    issue: &Issue,
    json_mode: bool,
    details_writer: &mut Option<fs::File>,
    output_writer: &mut Option<fs::File>,
) {
    if let Some(detail_out) = details_writer
        && let Ok(json_str) = serde_json::to_string(issue)
    {
        let _ = writeln!(detail_out, "{json_str}");
        let _ = detail_out.flush();
    }
    let rendered = if json_mode {
        output::render_json(issue)
    } else {
        output::render_human(issue)
    };
    if let Some(file_out) = output_writer {
        let _ = writeln!(file_out, "{rendered}");
        let _ = file_out.flush();
    } else {
        println!("{rendered}");
    }
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
    let mut byte_offset = compute_initial_byte_offset(&path, filter.from_line);
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

    loop {
        let new_issues = poll_session_lines(&path, &mut byte_offset, &mut last_line, &mut state);
        for issue in &new_issues {
            emit_watch_issue(issue, filter.json, &mut details_writer, &mut output_writer);
        }
        if !new_issues.is_empty() {
            all_issues.extend(new_issues);
            last_activity = Instant::now();
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

/// Check if pre-lowered text matches the pre-lowercased dump filter.
fn matches_dump_filter(text_lower: &str, filter_lower: Option<&str>) -> bool {
    filter_lower.is_none_or(|f| text_lower.contains(f))
}

/// A formatted dump block with a label prefix and the block text.
struct DumpBlock {
    label: String,
    text: String,
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
            let db = format_dump_block(index, role, block);
            if db.text.len() <= MIN_DUMP_TEXT_LENGTH {
                continue;
            }
            if !matches_dump_filter(&db.text.to_lowercase(), filter_lower) {
                continue;
            }
            let truncated = truncate_at(&db.text, DUMP_TRUNCATE_LENGTH);
            println!("{}: {truncated}", db.label);
        }
    } else if let Some(text) = content.as_str() {
        if text.len() <= MIN_DUMP_TEXT_LENGTH {
            return;
        }
        if !matches_dump_filter(&text.to_lowercase(), filter_lower) {
            return;
        }
        let truncated = truncate_at(text, DUMP_TRUNCATE_LENGTH);
        println!("L{index} [{role}]: {truncated}");
    }
}

/// Format a content block for dump output.
fn format_dump_block(index: usize, role: &str, block: &serde_json::Value) -> DumpBlock {
    let block_type = block["type"].as_str().unwrap_or("");
    match block_type {
        "text" => {
            let text = block["text"].as_str().unwrap_or("").to_string();
            DumpBlock {
                label: format!("L{index} [{role}] text"),
                text,
            }
        }
        "tool_use" => format_tool_use_dump(index, role, block),
        "tool_result" => {
            let text = tool_result_text(block);
            DumpBlock {
                label: format!("L{index} [{role}] result"),
                text,
            }
        }
        _ => DumpBlock {
            label: format!("L{index} [{role}] {block_type}"),
            text: String::new(),
        },
    }
}

/// Format a `tool_use` block for dump output.
fn format_tool_use_dump(index: usize, role: &str, block: &serde_json::Value) -> DumpBlock {
    let name = block["name"].as_str().unwrap_or("");
    let input = &block["input"];
    match name {
        "Bash" => {
            let cmd = input["command"].as_str().unwrap_or("");
            DumpBlock {
                label: format!("L{index} [{role}] Bash"),
                text: cmd.to_string(),
            }
        }
        "Read" | "Write" => {
            let file_path = input["file_path"].as_str().unwrap_or("");
            DumpBlock {
                label: format!("L{index} [{role}] {name}"),
                text: file_path.to_string(),
            }
        }
        "Edit" => {
            let file_path = input["file_path"].as_str().unwrap_or("");
            let old = truncate_at(input["old_string"].as_str().unwrap_or(""), 100);
            let new_str = truncate_at(input["new_string"].as_str().unwrap_or(""), 100);
            DumpBlock {
                label: format!("L{index} [{role}] Edit"),
                text: format!("{file_path}\n  old: {old}\n  new: {new_str}"),
            }
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
            DumpBlock {
                label: format!("L{index} [{role}] AskUser"),
                text: parts.join("; "),
            }
        }
        "Agent" => {
            let desc = input["description"].as_str().unwrap_or("");
            DumpBlock {
                label: format!("L{index} [{role}] Agent"),
                text: desc.to_string(),
            }
        }
        _ => {
            let raw = serde_json::to_string(input).unwrap_or_default();
            DumpBlock {
                label: format!("L{index} [{role}] {name}"),
                text: truncate_at(&raw, 300).to_string(),
            }
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
