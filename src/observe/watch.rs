use std::fs;
use std::io::{self, BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use tokio::sync::mpsc;
use tokio::time::sleep;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::RUNTIME;

use super::application::ObserveFilter;
use super::classifier;
use super::output;
use super::scan::apply_filters;
use super::session;
use super::types::{Issue, ScanState};

#[derive(Serialize)]
struct WatchStarted<'a> {
    status: &'static str,
    session: &'a str,
    from_line: usize,
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
    let Ok(file) = open_session_file(path, *byte_offset) else {
        return Vec::new();
    };
    let reader = BufReader::new(file);
    let mut issues = Vec::new();
    for line_result in reader.lines() {
        append_classified_line(line_result, byte_offset, last_line, state, &mut issues);
    }
    issues
}

fn open_session_file(path: &Path, byte_offset: u64) -> Result<fs::File, io::Error> {
    let mut file = fs::File::open(path)?;
    file.seek(SeekFrom::Start(byte_offset))?;
    Ok(file)
}

fn append_classified_line(
    line_result: Result<String, io::Error>,
    byte_offset: &mut u64,
    last_line: &mut usize,
    state: &mut ScanState,
    issues: &mut Vec<Issue>,
) {
    let Ok(line) = line_result else {
        return;
    };
    *byte_offset += line.len() as u64 + 1;
    let index = *last_line;
    *last_line += 1;
    issues.extend(classifier::classify_line(index, &line, state));
}

/// Write a line to a file and flush, printing a warning on failure.
fn write_and_flush(file: &mut fs::File, line: &str) {
    let _ = writeln!(file, "{line}");
    let _ = file.flush();
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
        write_and_flush(detail_out, &json_str);
    }
    let rendered = if json_mode {
        output::render_json(issue)
    } else {
        output::render_human(issue)
    };
    if let Some(file_out) = output_writer {
        write_and_flush(file_out, &rendered);
    } else {
        println!("{rendered}");
    }
}

/// Execute watch mode with file-event-driven updates and a fallback poll interval.
///
/// Uses `notify` to receive filesystem events for immediate reaction when the
/// session file changes, with a fallback `poll_duration` sleep to catch any
/// missed events.
pub(super) fn execute_watch(
    session_id: &str,
    poll_interval: u64,
    timeout: u64,
    filter: &ObserveFilter,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;
    let from_line = super::scan::resolve_effective_from_line(filter, &path)?;

    if filter.json {
        let session = path.to_string_lossy();
        println!(
            "{}",
            serde_json::to_string(&WatchStarted {
                status: "started",
                session: session.as_ref(),
                from_line,
            })
            .expect("watch status serializes")
        );
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

    RUNTIME.block_on(async {
        let (event_tx, mut event_rx) = mpsc::channel::<notify::Result<notify::Event>>(32);

        let mut watcher = RecommendedWatcher::new(
            move |res| {
                let _ = event_tx.blocking_send(res);
            },
            notify::Config::default(),
        )
        .map_err(|e| {
            CliError::from(CliErrorKind::session_parse_error(format!(
                "cannot create file watcher: {e}"
            )))
        })?;

        watcher
            .watch(&path, RecursiveMode::NonRecursive)
            .map_err(|e| {
                CliError::from(CliErrorKind::session_parse_error(format!(
                    "cannot watch session file: {e}"
                )))
            })?;

        loop {
            tokio::select! {
                Some(_event) = event_rx.recv() => {
                    // file changed — drain any additional queued events immediately
                    while event_rx.try_recv().is_ok() {}
                }
                () = sleep(poll_duration) => {
                    // fallback poll to catch missed events
                }
            }

            let prev_last_line = last_line;
            let new_issues =
                poll_session_lines(&path, &mut byte_offset, &mut last_line, &mut state);

            if last_line > prev_last_line {
                last_activity = Instant::now();
            }

            let filtered_new = apply_filters(new_issues, filter)?;
            for issue in &filtered_new {
                emit_watch_issue(issue, filter.json, &mut details_writer, &mut output_writer);
            }
            all_issues.extend(filtered_new);

            if timeout > 0 && last_activity.elapsed() > timeout_duration {
                break;
            }
        }

        Ok::<(), CliError>(())
    })?;

    if filter.summary {
        println!("{}", output::render_summary(&all_issues, last_line));
    }

    Ok(0)
}
