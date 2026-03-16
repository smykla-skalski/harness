use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};

use super::ObserveFilterArgs;
use super::classifier;
use super::output;
use super::scan::apply_filters;
use super::session;
use super::types::{Issue, ScanState};

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
    if let Err(e) = file.seek(SeekFrom::Start(*byte_offset)) {
        eprintln!("warning: seek failed on session file: {e}");
        return Vec::new();
    }
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

/// Write a line to a file and flush, printing a warning on failure.
fn write_and_flush(file: &mut fs::File, line: &str, label: &str) {
    if let Err(e) = writeln!(file, "{line}") {
        eprintln!("warning: failed to write {label}: {e}");
    }
    if let Err(e) = file.flush() {
        eprintln!("warning: failed to flush {label}: {e}");
    }
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
        write_and_flush(detail_out, &json_str, "issue details");
    }
    let rendered = if json_mode {
        output::render_json(issue)
    } else {
        output::render_human(issue)
    };
    if let Some(file_out) = output_writer {
        write_and_flush(file_out, &rendered, "issue output");
    } else {
        println!("{rendered}");
    }
}

/// Execute watch mode with polling.
///
/// Tracks the byte offset in the session file so each poll cycle only reads
/// new lines instead of re-reading the entire file.
pub(super) fn execute_watch(
    session_id: &str,
    poll_interval: u64,
    timeout: u64,
    filter: &ObserveFilterArgs,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;
    let from_line = super::scan::resolve_effective_from_line(filter, &path)?;

    if filter.json {
        let status = json!({
            "status": "started",
            "session": path.to_string_lossy(),
            "from_line": from_line,
        });
        println!("{status}");
    }

    let mut state = ScanState::default();
    let mut all_issues: Vec<Issue> = Vec::new();
    let mut last_line = from_line;
    let mut last_activity = Instant::now();
    let mut byte_offset = compute_initial_byte_offset(&path, from_line);
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
        let prev_last_line = last_line;
        let new_issues = poll_session_lines(&path, &mut byte_offset, &mut last_line, &mut state);

        // Track log activity (any new lines), not just issue activity
        if last_line > prev_last_line {
            last_activity = Instant::now();
        }

        // Filter each batch before emitting
        let filtered_new = apply_filters(new_issues, filter)?;
        for issue in &filtered_new {
            emit_watch_issue(issue, filter.json, &mut details_writer, &mut output_writer);
        }
        all_issues.extend(filtered_new);

        if timeout > 0 && last_activity.elapsed() > timeout_duration {
            break;
        }

        thread::sleep(poll_duration);
    }

    if filter.summary {
        println!("{}", output::render_summary(&all_issues, last_line));
    }

    Ok(0)
}
